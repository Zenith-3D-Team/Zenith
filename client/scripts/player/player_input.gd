extends Node
## Keyboard and mouse to bridge commands: walking, driving, mining, picking up, building,
## rotating, opening machine screens, shooting, and the rest of Factorio's world controls. Also
## draws Factorio's marks on the hovered entity (cursor_overlay.gd: selection corners, inserter,
## drill, fluid and roboport marks), the held item's entity as a translucent model where it would
## go (red where it can't: none left, out of reach, something in the way) with its marks, the box
## dragged with a planner or the copy tools, and the clipboard's ghosts while pasting.
##
## Keys are InputMap actions (controls.gd, rebindable in Settings). The mouse, as in Factorio:
##   left: build the held item (drag: along the way), open a machine, use a planner or tool
##   Shift+left: build a ghost of the held item; with nothing held, paste the copied settings
##   Ctrl+left / Ctrl+right: fast transfer: put the held stack (half) into the entity under the
##       mouse (a belt: onto its lanes), or with nothing held take its output (half); held down,
##       each entity the mouse crosses gets the same (Shift+left's paste too)
##   right: mine; Shift+right: copy the entity's settings
## and the keys: Q pipette (over an entity: hold its item in its quality, also instead of something
## else held, or its ghost if there are none; over a window's slot: that item) or clear the cursor; Z drop one held item (into the entity under the mouse, onto a belt,
## or on the ground); R / Shift+R rotate; H / V flip what is being built (or the entity under the
## mouse); Alt Alt-mode; Ctrl+C / Ctrl+X copy or cut an area (drag), Ctrl+V paste it; Ctrl+Z /
## Ctrl+Y undo and redo (this client's own building and mining, and what the mod remembers:
## blueprints placed, planner marks, pasted settings, rotations); Alt+B / Alt+D / Alt+U blueprint,
## deconstruction and upgrade tools; Alt+L personal logistic requests on or off. With a planner
## held, dragging draws Factorio's selection box in its colour and marks what it will take
## (Shift: cancel; an upgrade planner's right-drag downgrades). A held blueprint (a book: its active
## page) is placed when the button goes down, as in Factorio: a click places what can be built
## (normal), Shift+click forces it (trees and rocks in the way are marked for deconstruction),
## Ctrl+Shift+click super-forces it; dragging places it again every blueprint's length along the
## drag (its snap grid when it has one). Ctrl+Shift+left builds super-forced (trees and rocks in
## the way are marked for deconstruction); H / V flip a held blueprint too (the mod mirrors it,
## see planners.lua); Ctrl+mouse wheel cycles the held item's quality,
## Shift+mouse wheel the held book's pages. Alt+R / Alt+G / Alt+C red, green and copper wire (wire_tool.gd;
## Shift+click on a pole removes its copper cables).
##
## Over a window (the inventory, quickbar, ...) the mouse belongs to the UI: nothing in the world
## is hovered, built or aimed at through it. Keys still walk and shoot, as in Factorio.
##
## Walk, drive, mine, pickup and shoot commands only last half a second in the mod, so they are
## repeated while held.
## Command-line options (after `--`): --open=<unit> opens that entity's screen once it has loaded (a
## building, or a train carriage or car near the character); --rail-from=<x>,<y> anchors the rail
## planner at the rail end nearest that point once the world is in (for screenshots, with --ui-hold).

const Settings := preload("res://scripts/menu/settings.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const Predicted := preload("res://scripts/world/predicted.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const CameraRig := preload("res://scripts/player/camera_rig.gd")
const CombatLayer := preload("res://scripts/world/combat.gd")
const Hud := preload("res://scripts/ui/hud.gd")
const Avatar := preload("res://scripts/player/avatar.gd")
const Controls := preload("res://scripts/player/controls.gd")
const MoverLayer := preload("res://scripts/world/movers.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
const CursorOverlay := preload("res://scripts/player/cursor_overlay.gd")
const GroundItems := preload("res://scripts/world/ground_items.gd")
const PoleCoverage := preload("res://scripts/player/pole_coverage.gd")
const PipelineMarks := preload("res://scripts/player/pipeline_marks.gd")
const UndergroundPairs := preload("res://scripts/world/underground_pairs.gd")
const BlueprintPreview := preload("res://scripts/player/blueprint_preview.gd")
## The previews' plain marks (an item's box without a model, the drag box, pole lines) ride the hills.
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const RoboportLinks := preload("res://scripts/world/roboport_links.gd")
const WireTool := preload("res://scripts/player/wire_tool.gd")
const GhostShader := preload("res://shaders/ghost.gdshader")
const BpString := preload("res://scripts/ui/factorio/bp_string.gd")
const TileBrush := preload("res://scripts/player/tile_brush.gd")
const RailPlanner := preload("res://scripts/player/rail_planner.gd")
const RailBlocks := preload("res://scripts/player/rail_blocks.gd")
const CapsuleAim := preload("res://scripts/player/capsule_aim.gd")
const DragBuild := preload("res://scripts/player/drag_build.gd")
const SpiderRemote := preload("res://scripts/player/spider_remote.gd")
const VisualTurns := preload("res://scripts/world/visual_turns.gd")
const Ghosts := preload("res://scripts/world/ghosts.gd")
const AimPick := preload("res://scripts/world/aim_pick.gd")
const ResourceHints := preload("res://scripts/player/resource_hints.gd")
const Switches := preload("res://scripts/switches.gd")
const Sfx := preload("res://scripts/fx/sfx.gd")

const REPEAT := 0.15
## First person (K7): how far the crosshair's ray looks for an entity before the ground's point
## decides (tiles); the bridge still refuses what is out of the character's reach.
const AIM_RANGE := 64.0
## A walk's angle is sent again once the wanted direction (keys turned by the camera, or the stick)
## moved this many thousandths of a turn (about 1 degree).
const TURN_STEP := 3
const STICK_DEAD_ZONE := 0.25
## The character's build_distance in Factorio without bonuses (`build_reach()` has the real one).
const BUILD_REACH := 10.0
## Held like a building but used on release: a blueprint (or book) is placed, a planner dragged.
const PLANNERS := ["blueprint", "blueprint-book", "deconstruction-planner", "upgrade-planner"]
## Tools the shortcuts put in the cursor without an item in the inventory (Factorio spawns them):
## tool -> the item whose icon the cursor shows.
const TOOLS := {
	"copy": "copy-paste-tool", "cut": "cut-paste-tool", "paste": "blueprint",
	"blueprint": "blueprint", "decon": "deconstruction-planner",
	"red-wire": "red-wire", "green-wire": "green-wire", "copper-wire": "copper-wire",
	"spidertron": "spidertron-remote", "artillery": "artillery-targeting-remote", "discharge": "discharge-defense-remote",
}
## Selection colours: the border_color of each tool's select / alt_select (Shift) / reverse_select
## (right-drag) in Factorio's item prototypes (base/prototypes/item.lua): blueprint blue (Shift a
## lighter blue), copy and cut white (copy with Shift cyan), deconstruction red, upgrade green,
## their Shift cancels orange, the upgrade planner's downgrade yellow.
const SELECT_COLORS := {
	"blueprint": Color8(57, 156, 251), "blueprint_alt": Color(0.3, 0.8, 1.0), "copy": Color(1, 1, 1), "copy_alt": Color(0, 1, 1),
	"cut": Color(1, 1, 1), "cut_alt": Color(1, 1, 1), "decon": Color8(255, 24, 24), "decon_alt": Color8(239, 153, 34),
	"upgrade": Color8(71, 255, 73), "upgrade_alt": Color8(239, 153, 34), "upgrade_reverse": Color8(246, 255, 0),
}
## The dragged box is only its border, as Factorio draws it (tiles wide); what it takes gets
## brackets in the same colour.
const BOX_EDGE := 0.06
## Trees and rocks: what "trees and rocks only" takes, and what blueprints and copies leave out.
const NATURE_TYPES := ["tree", "simple-entity", "cliff", "plant"]
## A left click with nothing held, or E, opens these: what Factorio 2.1.23 opens a window for
## (tools/ui_reference's rules_openable built and opened every buildable entity). Steam engines and
## turbines, solar panels, walls, gates, undergrounds, rails, fluid wagons, lightning rods, fusion
## generators and thrusters open nothing there.
const OPENABLE_TYPES := [
	"container", "logistic-container", "linked-container", "infinity-container", "assembling-machine",
	"furnace", "lab", "mining-drill", "boiler", "burner-generator", "reactor", "rocket-silo",
	"inserter", "splitter", "lane-splitter", "loader", "loader-1x1", "constant-combinator", "arithmetic-combinator",
	"decider-combinator", "selector-combinator", "train-stop", "locomotive", "cargo-wagon",
	"artillery-wagon", "roboport", "accumulator", "radar", "ammo-turret", "artillery-turret", "car",
	"spider-vehicle", "power-switch", "programmable-speaker", "display-panel", "lamp", "storage-tank",
	"pump", "offshore-pump", "electric-pole", "cargo-landing-pad", "space-platform-hub", "cargo-bay",
	"electric-energy-interface", "asteroid-collector", "agricultural-tower", "heat-interface",
	"electric-turret", "fluid-turret", "beacon", "fusion-reactor", "pipe", "pipe-to-ground", "heat-pipe",
	"land-mine", "transport-belt", "rail-signal", "rail-chain-signal",
]
## Movers a click opens: their inventories (a car's trunk, a wagon's cargo), a train's schedule.
const OPENABLE_MOVERS := ["car", "spider-vehicle", "locomotive", "cargo-wagon", "artillery-wagon", "infinity-cargo-wagon"]
## Movers hovered and picked in 3D (includes fluid wagons so rolling stock wins over rails/pipes behind it).
const HOVER_MOVERS := ["car", "spider-vehicle", "locomotive", "cargo-wagon", "fluid-wagon", "artillery-wagon",
	"infinity-cargo-wagon"]
## Movers the right button mines (Factorio mines every vehicle and wagon, with what is inside).
const MINEABLE_MOVERS := ["car", "spider-vehicle", "locomotive", "cargo-wagon", "fluid-wagon",
	"artillery-wagon", "infinity-cargo-wagon"]
## Undo keeps this many of the client's own actions.
const HISTORY := 50
## Entity types that can have module inventories in Factorio.
const MODULE_ENTITY_TYPES := ["assembling-machine", "furnace", "rocket-silo", "mining-drill", "lab", "beacon"]
## VisualTurns-eligible entity types with no Factorio copy_settings support (rotated locally only).
const NON_PASTABLE_VT_TYPES := ["solar-panel", "radar", "reactor", "lightning-attractor"]
## Entity types Factorio never rotates on R and Zenith doesn't visually turn (C3).
const NON_ROTATABLE_TYPES := ["wall", "lamp", "pipe", "heat-pipe", "infinity-pipe", "heat-interface",
	"land-mine", "rail-support", "cargo-bay", "space-platform-hub", "thruster", "crusher",
	"electric-pole", "power-switch", "programmable-speaker"]
## World entities without configurable settings to paste onto (C9).
const NON_CONFIGURABLE_PASTE_TYPES := ["tree", "simple-entity", "resource", "cliff", "plant",
	"corpse", "character-corpse", "rail-remnants"]

## --cursor-icon-world=old: hide the held building's icon over the world while its build ghost is visible.
static var cursor_icon_world := not (Switches.has("--cursor-icon-world=old"))
## --mover-pick-3d=off: old mover hover priority (only when ground has no openable non-belt entity).
static var mover_pick_3d := not (Switches.has("--mover-pick-3d=off"))
## --click-open-held=off: plain LMB with a placeable entity over an openable building/mover builds instead of opening.
static var click_open_held := Switches.on("--click-open-held")
## --clean-shot (model screenshots): no hover highlight, whatever the mouse is over.
var _clean_shot := Switches.has("--clean-shot")
## `--hover-highlight-cache=off`: rebuild hover/build highlight geometry and chunk scans every frame.
static var hover_highlight_cache := Switches.on("--hover-highlight-cache")
var _hl_cache_valid := false
var _hl_cache_key: Array = []
var highlight_cache_hits := 0
var highlight_rebuilds := 0
## Why the held entity can't be built on this surface ("" when it can), shown under the cursor.
var _build_refusal := ""
var world: WorldMirror
## The remote view's fog (remote_fog.gd), for what draws over the world (Alt-mode icons). Untyped.
var remote_fog: Node
var rig: CameraRig
var hud: Hud
## What was just built, drawn before the game confirms it (scripts/world/predicted.gd).
var predicted: Predicted
var combat: CombatLayer
var avatar: Avatar
## Vehicles and wagons are movers, not world entities: they are opened through this.
var movers: MoverLayer = null
## Items lying on the ground (ground_items.gd), which the right button picks up (J18). Untyped.
var ground_items = null
## Electric poles' supply areas while a pole is held or hovered (J4).
var pole_cover := PoleCoverage.new()
## Factorio 2.1's fluid pipeline visualization, hovered or held in Alt-mode (N9).
var pipeline_vis := PipelineMarks.new()
var wires = null  # wires.gd, for where a dragged wire hangs from
## The belt items' layer (belt_items.gd), which shows an item Z drops on a belt at once (drop_show_now). Untyped.
var belt_items = null
var wire_tool := WireTool.new()
## The spidertron remote's selection and waypoints (cursor_tool "spidertron").
var spider_remote := SpiderRemote.new()
## Rail signal & stop attachment snapping and signal-block overlays (C1).
var rail_blocks := RailBlocks.new()

## Item held for building ("" for none). Its entity is assumed to share the item's name.
var cursor_item := ""
## Which stack a held blueprint or planner is: 0 the first of that item (or the one picked up), -1
## the one taken from the library (the mod keeps it out of the inventory), else that main slot.
var cursor_slot := 0
## The quality the held item builds in (Ctrl+mouse wheel), Factorio 2.x.
var cursor_quality := "normal"
## A tool from a shortcut instead of an item (TOOLS), or "".
var cursor_tool := ""
var build_dir := 0
## Train carriages, which the mod builds on a rail (rolling_stock_spot; building.lua's list).
const ROLLING_STOCK := {"locomotive": true, "cargo-wagon": true, "fluid-wagon": true, "artillery-wagon": true, "infinity-cargo-wagon": true}
## The rails rolling stock is put on, and how far from the cursor one is looked for (building.lua).
const STOCK_RAILS := {"straight-rail": true, "legacy-straight-rail": true}
const RAIL_SEARCH := 3.0
## The line over the quickbar while a tool is held (a constant: it was a dictionary made every frame).
const TOOL_HINTS := {"copy": "Drag to copy · Right click: cancel", "cut": "Drag to cut · Right click: cancel",
	"paste": "Click to paste · R: rotate · Right click: cancel", "blueprint": "Drag to make a blueprint · Right click: cancel",
	"decon": "Drag to deconstruct · Shift: cancel deconstruction",
	"red-wire": "Click two entities to connect them (again: disconnect) · Right click: let go",
	"green-wire": "Click two entities to connect them (again: disconnect) · Right click: let go",
	"copper-wire": "Click two poles to connect them (again: disconnect) · Shift+click a pole: remove its cables",
	"spidertron": "Drag: select spidertrons · Shift+drag: add · Right-drag: remove · Click: send · Shift+click: queue",
	"artillery": "Click: call an artillery strike there (a flare) · Right click: put away",
	"discharge": "Click: fire the discharge defense equipment · Right click: put away"}

## Flip what is built (H / V): the entity is mirrored.
var build_mirror := false
var hovered: WorldMirror.Rec = null
var _alt_clicked := false
## The vehicle or wagon under the mouse (MoverLayer.pick_ray), or []; it wins over the rail or
## ground under it, so `hovered` is null then.
var hovered_mover: Array = []
## Reusable synthetic record for the hovered mover, handed to EntityInfo and copy/paste so caching stays stable.
var _hovered_mover_rec: WorldMirror.Rec = null
var ground := Vector2.ZERO
var has_ground := false
## First person picks what the crosshair's ray meets first (K7, aim_pick.gd); --fp-pick=ground picks
## from where it meets the ground, as before.
var fp_pick_models := not Switches.has("--fp-pick=ground")
## What that ray met this frame (AimPick.pick: [Rec, distance, point, outward normal, selection
## rect]) or [], and the cursor point it put `ground` at.
var _aim: Array = []
var _aim_ground := Vector2.INF
## The mouse is over the UI this frame.
var over_gui := false
## The entity whose settings Shift+right click copied: {"u", "p", "x", "y", "name"} or {}.
var copied_settings := {}

var _walk_dir := -1
var _walk_turn := -1  # the angle last sent with walk, thousandths of a turn, or -1
var _walk_timer := 0.0
## Joypads whose left stick has been seen centred since they were plugged in (stick_of).
var _sticks_centred := {}
## Tests set it: the joypads _stick reads, as stick_of takes them, instead of Input's.
var joypads_for_test = null
var _drive_code := 0  # the last drive command sent, as accelerate * 3 + steer; 0 is none
var _mine_timer := 0.0
var _mining := false
var _mine_target: WorldMirror.Rec = null
## What the last `mine` was for (a mover's unit, an entity's key, or null for nothing): a new one
## under the mouse is sent at once (J26).
var _mine_key: Variant = null
## Tests set it: where the character stands, for the cursor's offset from it in `mine`, when there
## is no avatar.
var character_at_for_test := Vector2.INF
## Issue #24: no swing (sound, sparks, dust) at something out of the character's reach, as in
## Factorio: the swing starts on the click (avatar.mine_hint, I20) only when the target is within the
## bridge's own reach (puppet.lua can_hand_mine), and stops on the bridge's "Out of reach" while the
## button stays on that target. `--mine-reach-check=off`: the hint on every click, as before.
static var mine_reach_check := Switches.on("--mine-reach-check")
## The target the bridge last refused as out of reach while it was held, and where the character
## stood then: no swing at it again until another target, the character moving or the button let go.
var _reach_refused_key: Variant = null
var _reach_refused_at := Vector2.INF
## Whether that refusal was for reach (moving tries again) or for the target itself (it stays).
var _refused_for_reach := true
## Prototypes the bridge refused as kinds that can't be mined by hand ("This needs a mining drill"):
## every entity of them is silent until the button is let go, so a sweep over a uranium patch doesn't
## swing on each new tile before its refusal comes back.
var _refused_protos := {}
## The prototype of the target the last `mine` was for (an entity's or a mover's), for _refused_protos.
var _mine_proto := 0
## Every reason puppet.lua's can_hand_mine refuses a hand mine with, and what it refuses: "reach" the
## target from where the character stands, "target" that entity, "kind" its whole prototype. Keep in
## step with can_hand_mine's `return false, "<reason>"` lines (issue #24).
const MINE_REFUSALS := {
	"Out of reach": "reach",
	"Can't mine that": "target",
	"This needs a mining drill": "kind",
	"This needs a pump or drill": "kind",
}
## The mover last marked for deconstruction from the remote view while the button is held.
var _remote_marked_mover := 0
var _pickup_timer := 0.0
## F held (a `pickup` sent since it was last let go): its release sends `pickup_stop`, so the bridge picks no more
## (it kept a pickup 30 ticks after the last one, picking on for up to half a second); `--pickup-stop=off` as before.
var _pickup_held := false
var pickup_stop := Switches.on("--pickup-stop")
## F read with exactly its modifiers, as shooting and dropping are: Ctrl+F (search) and Alt+F (the personal
## roboport) held don't pick up, as in Factorio. `--pickup-exact=off`: any modifier held too, as before.
var pickup_exact := Switches.on("--pickup-exact")
var _drop_timer := 0.0
var _shoot_mode := -1
var _shoot_timer := 0.0
## K13: the entity a held repair pack is repairing (its unit; 0 none) and when to say so again.
var repair_unit := 0
var _repair_timer := 0.0
var _rmb_down := false
## An upgrade planner's right-drag (Factorio's downgrade) is in progress from here.
var _reverse_from := Vector2.INF
## Blueprint drag-placing: where it was last placed, the axis the drag took (ZERO until it moved a
## step), the build mode of the click.
var _bp_last := Vector2.INF
var _bp_axis := Vector2.ZERO
var _bp_mode := 0
## Ctrl+click held down (MOUSE_BUTTON_LEFT / RIGHT, or NONE) and the entity it last went to; a
## Shift+left paste held down and the entity it last pasted to.
var _fast_button := MOUSE_BUTTON_NONE
var _fast_target: Variant = null  # the key of what this Ctrl+click drag last did (_fast_pick)
var _fast_putting := false  # this Ctrl+click drag began with a stack held (puts), else it takes
var _paste_dragging := false
## Camera turn rate (rad/s) or mouse cursor speed (px/s) above which hover-panel rebuilds and
## `hinfo` requests pause until motion slows, so spinning the camera doesn't churn UI/UDP.
const HOVER_FAST_TURN := PI * 0.5  # 90 deg/s
const HOVER_FAST_MOUSE := 1200.0   # px/s
var _last_cam_dir := Vector3.ZERO
var _last_hover_screen := Vector2.INF
var _last_hover_usec := 0
## The character (or what it drives) moving faster than this, tiles a second: the hover panel is rebuilt at most
## about ten times a second (entity_info.gd RUN_REBUILD_MSEC, --hover-rate=off).
const HOVER_RUN_SPEED := 3.0
var _last_hover_focus := Vector2.INF
var _paste_target_key: Variant = null
## The blueprint window's "Select new contents": the blueprint tool's area goes into this
## blueprint (a main slot, -1 the library one) instead of a new one; 0 none.
var reselect_slot := 0
var _lmb_down := false
var _remote_marked: WorldMirror.Rec = null  # marked for deconstruction during this right click (remote view)
var _lmb_shift := false  # Shift was held when the left button went down: ghosts, cancel boxes
var _lmb_super := false  # Ctrl+Shift: super-forced build (obstacles marked for deconstruction)
var _drag_from := Vector2.ZERO  # where a planner drag started
var _rail_click := false  # this left click was the rail planner's (anchoring or building)
var _ghost := MeshInstance3D.new()
var _drag_box := MeshInstance3D.new()
## Build previews from `eprops`: lines to the poles a new pole would connect to. (A pole's supply area
## is pole_coverage.gd's, an underground's reach underground_pairs.gd's, both overlay marks.)
var _reach_lines := MeshInstance3D.new()
var _reach_mesh := ImmediateMesh.new()
var _ghost_ok := GroundHeight.mark_material(Color(0.3, 1.0, 0.4, 0.35), false)
var _ghost_bad := GroundHeight.mark_material(Color(1.0, 0.3, 0.25, 0.35), false)
var _ghost_blue := GroundHeight.mark_material(Color(0.4, 0.65, 1.0, 0.35), false)
## The held item's entity as its model, translucent (ghost.gdshader): whitish where it can go,
## Factorio's ghost blue for a ghost, red where it can't.
var _ghost_model := MeshInstance3D.new()
var _ghost_model_tints := {"ok": Color(0.85, 1.0, 0.85, 0.5), "ghost": Color(0.58, 0.68, 1.0, 0.42), "bad": Color(1.0, 0.3, 0.25, 0.5)}
var _ghost_model_materials := {}
## A held cargo bay's edge pieces round it (ModelLibrary.cargo_places), as it would be framed there.
var _ghost_pieces: Array[MeshInstance3D] = []
## Selection brackets, arrows and areas (cursor_overlay.gd).
var _overlay := CursorOverlay.new()
## Which roboports are linked, for the lines between them (H14).
var roboport_links: RoboportLinks = null
## A held blueprint's and the clipboard's entities at the cursor, as their models (K11).
var bp_preview := BlueprintPreview.new()
## Goes up with each new clipboard (`clip` refills the same array).
var _clip_version := 0
var _open_on_start := 0
var _rail_from := Vector2.INF
var _open_name_on_start := ""
## Undo and redo: what this client built and mined, newest last ({"do": "build"|"mine", "item",
## "x", "y" (tiles), "d"}).
var _undo: Array = []
var _redo: Array = []
## Tiles in the cursor (tile_brush.gd), the rail planner (rail_planner.gd), capsules
## (capsule_aim.gd) and building while dragging (drag_build.gd).
var tile_brush := TileBrush.new()
var rail_planner := RailPlanner.new()
var capsule_aim := CapsuleAim.new()
var drag := DragBuild.new()


## Registers the input actions (controls.gd) with their default keys. Call once before the scene
## starts; Settings → Controls (settings.gd apply_bindings) rebinds them after.
static func define_actions() -> void:
	Controls.define()


func _ready() -> void:
	for box in [_ghost, _drag_box]:
		box.mesh = Visuals.box_mesh()
		box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		box.visible = false
		world.add_child(box)
	_box_edges()
	_reach_lines.mesh = _reach_mesh
	_reach_lines.material_override = GroundHeight.mark_material(Color(0.95, 0.75, 0.3, 0.9), false)
	_reach_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(_reach_lines)
	for k in _ghost_model_tints:
		var m := ShaderMaterial.new()
		m.shader = GhostShader
		m.set_shader_parameter("tint", _ghost_model_tints[k])
		_ghost_model_materials[k] = m
	_ghost_model.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ghost_model.visible = false
	world.add_child(_ghost_model)
	world.add_child(_overlay)
	pipeline_vis.world = world
	world.add_child(pipeline_vis)
	bp_preview.world = world
	bp_preview.replace_groups = REPLACE_GROUPS
	bp_preview.xprops = func(p: ProtoDB.EntityProto) -> Dictionary: return _xprops(p)
	bp_preview.refused = func(proto_id: int) -> bool: return hud.ui.model.cant_build_reason(proto_id) != ""
	world.add_child(bp_preview)
	hud.ui.model.clipboard_changed.connect(func() -> void: _clip_version += 1)
	roboport_links = RoboportLinks.new(world)
	roboport_links.radius_of = _logistic_radius
	wire_tool.world = world
	wire_tool.wires = wires
	wire_tool.model = hud.ui.model
	world.add_child(wire_tool)
	for tool in [tile_brush, rail_planner, capsule_aim]:
		tool.pi = self
		world.add_child(tool)
	drag.pi = self
	hud.ui.player = self
	for arg in Switches.args():
		if arg.begins_with("--open="):
			var what := arg.get_slice("=", 1)
			if what.is_valid_int():
				_open_on_start = int(what)
			else:  # a prototype name: the nearest one (UI reference shots, tools/ui_reference)
				_open_name_on_start = what
		elif arg.begins_with("--rail-from="):
			var xy := arg.get_slice("=", 1).split(",")
			_rail_from = Vector2(float(xy[0]), float(xy[1]))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		# Not while an add-on has the camera (1.7): the hidden first-person view drifted, seen on release.
		if rig.first_person and not rig.taken() and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			rig.look(mm.relative)
		elif mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			rig.rotate_free(-mm.relative.x * 0.3)
			rig.tilt(mm.relative.y * 0.3 * rig.look_sign)
	elif Controls.pressed(event, "reverse_rotate"):
		_rotate(true)
	elif Controls.pressed(event, "rotate"):
		_rotate(false)
	elif Controls.pressed(event, "pipette") or Controls.pressed(event, "clear_cursor"):
		_pipette_or_clear()
	elif Controls.pressed(event, "flip_horizontal"):
		_flip(false)
	elif Controls.pressed(event, "flip_vertical"):
		_flip(true)
	elif Controls.pressed(event, "alt_mode"):
		# Alt-mode toggles when Alt is let go, unless it was held for an Alt+click (Factoriopedia).
		_alt_clicked = false
	elif event is InputEventKey and event.is_action_released("alt_mode"):
		if not _alt_clicked:
			hud.ui.set_alt_mode(not hud.ui.alt_mode)
		_alt_clicked = false
	elif Controls.pressed(event, "copy"):
		hold_tool("copy")
	elif Controls.pressed(event, "cut"):
		hold_tool("cut")
	elif Controls.pressed(event, "paste"):
		if hud.ui.model.clipboard.is_empty():
			hud.show_message("The clipboard is empty")
		else:
			hold_tool("paste")
	elif Controls.pressed(event, "undo"):
		undo()
	elif Controls.pressed(event, "redo"):
		redo()
	elif Controls.pressed(event, "give_blueprint"):
		hold_tool("blueprint")
	elif Controls.pressed(event, "give_deconstruction_planner"):
		hold_tool("decon")
	elif Controls.pressed(event, "toggle_rail_layer") and cursor_tool == "" and not rail_planner.use_of(cursor_item).is_empty():
		# The rail layer's key is shared (Controls.SHARED): Factorio 2.1's G also gets in a vehicle, Zenith's
		# Alt+R also gives a red wire. Rails in hand take it, anything else falls through to the other.
		rail_planner.toggle_layer()
	elif Controls.pressed(event, "give_red_wire"):
		hold_tool("red-wire")
	elif Controls.pressed(event, "give_green_wire"):
		hold_tool("green-wire")
	elif Controls.pressed(event, "give_copper_wire"):
		hold_tool("copper-wire")
	elif Controls.pressed(event, "give_upgrade_planner"):
		if _slot_of("upgrade-planner") > 0:
			hold("upgrade-planner")
		else:
			hud.ui.planners.give_new("upgrade_planner")
	elif Controls.pressed(event, "cycle_quality_up"):
		cycle_quality(1)
	elif Controls.pressed(event, "cycle_quality_down"):
		cycle_quality(-1)
	elif Controls.pressed(event, "cycle_blueprint_forwards"):
		_cycle_book(1)
	elif Controls.pressed(event, "cycle_blueprint_backwards"):
		_cycle_book(-1)
	elif Controls.pressed(event, "toggle_personal_logistics"):
		hud.ui.toggle_personal_logistics()
	elif Controls.pressed(event, "larger_tile_area"):
		tile_brush.resize(1)
	elif Controls.pressed(event, "smaller_tile_area"):
		tile_brush.resize(-1)
	elif Controls.pressed(event, "camera_left"):
		rig.rotate_step(-1)
	elif Controls.pressed(event, "camera_right"):
		rig.rotate_step(1)
	elif Controls.pressed(event, "factorio_view"):
		rig.toggle_factorio_view()
	elif Controls.pressed(event, "first_person"):
		rig.toggle_first_person()
	elif Controls.pressed(event, "toggle_projection"):
		hud.show_message(rig.toggle_projection())
	elif Controls.pressed(event, "toggle_help"):
		Settings.set_value("interface", "show_help", not bool(Settings.get_value("interface", "show_help")))
		hud.help.visible = bool(Settings.get_value("interface", "show_help"))
	elif Controls.pressed(event, "open_screen"):
		# E: closes whatever is open, else opens your own inventory, whatever is under the mouse
		# (owner: never the hovered building or vehicle; left click opens those).
		if hud.ui.is_open():
			hud.ui.close_all()
		else:
			hud.ui.toggle_inventory()
	elif Controls.pressed(event, "next_gun"):
		_next_gun()
	elif Controls.pressed(event, "enter_vehicle"):
		# Beside a rocket silo, Enter is for getting into its rocket: its screen has the Ride buttons.
		var silo := _silo_near() if avatar.vehicle == 0 else null
		if silo != null:
			_open(silo)
		else:
			Bridge.send({"t": "enter"})
	if Bridge.priority_queue and Bridge.connected and rig != null and hud != null and hud.ui != null and not hud.ui.remote:
		if (event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion) and not event.is_echo():
			if event.is_action("move_up") or event.is_action("move_down") or event.is_action("move_left") or event.is_action("move_right"):
				_update_walk(0.0)


## A rocket silo the character stands beside (within 6 tiles of its edge), or null.
func _silo_near() -> WorldMirror.Rec:
	var me: Vector2 = avatar.ground_position()
	for key in world.entities:
		var r: WorldMirror.Rec = world.entities[key]
		if r.pos.distance_to(me) < 11.0:
			var p = world.protos.entity(r.proto_id)
			if p != null and p.type == "rocket-silo":
				return r
	return null


func _mouse_button(mb: InputEventMouseButton) -> void:
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if not mb.pressed:
				return
			var up := mb.button_index == MOUSE_BUTTON_WHEEL_UP
			if not mb.ctrl_pressed and not mb.shift_pressed and hud.ui.scroll_help(-1 if up else 1):
				return  # the wheel over the help (F1) scrolls it when it doesn't fit
			# Factorio: Ctrl+wheel the held item's quality, Shift+wheel a held book's pages.
			if mb.ctrl_pressed and cursor_item != "":
				cycle_quality(1 if up else -1)
			elif mb.shift_pressed and cursor_item == "blueprint-book":
				_cycle_book(-1 if up else 1)
			else:
				rig.zoom(0.9 if up else 1.1)
		MOUSE_BUTTON_RIGHT:
			if not mb.pressed:
				return
			if mb.ctrl_pressed and not mb.shift_pressed:
				_fast_button = MOUSE_BUTTON_RIGHT
				_fast_target = null
				_fast_transfer(true)
			elif mb.shift_pressed and not mb.ctrl_pressed:
				_copy_settings()
			elif WireTool.is_wire(cursor_tool) and wire_tool.cancel():
				pass  # the hanging wire goes first, then the tool
			elif cursor_tool == "spidertron" and has_ground:
				_reverse_from = ground  # the remote's reverse select: take spidertrons out
			elif cursor_tool != "":
				hold("")  # Factorio: right click puts a tool away
			elif cursor_item == "upgrade-planner" and has_ground:
				_reverse_from = ground  # Factorio's reverse select: downgrade
			elif not rail_planner.anchor.is_empty():
				rail_planner.clear()  # the rail planner lets go of its rail end
			else:
				_rmb_down = true
				_mine_timer = 0.0
		MOUSE_BUTTON_LEFT:
			if not mb.pressed:
				return
			if mb.alt_pressed and _open_pedia():
				return
			_drag_from = ground
			_lmb_shift = mb.shift_pressed
			_lmb_super = mb.shift_pressed and mb.ctrl_pressed
			if mb.ctrl_pressed and not mb.shift_pressed:
				_fast_button = MOUSE_BUTTON_LEFT
				_fast_target = null
				_fast_transfer(false)
				return
			_lmb_down = true
			tile_brush.reset_drag()
			var ghost_click := mb.shift_pressed or hud.count_of(cursor_item) == 0 or hud.ui.remote
			if WireTool.is_wire(cursor_tool) or (mb.shift_pressed and cursor_item == "" and hovered != null and _is_pole(hovered)):
				_wire_click(mb.shift_pressed)
				_lmb_down = false
			elif cursor_tool == "" and cursor_item != "" and has_ground and rail_planner.click(cursor_item, ground, ghost_click):
				_rail_click = true
			elif cursor_tool == "paste":
				_paste()
				_lmb_down = false
			elif cursor_tool == "" and cursor_item in ["blueprint", "blueprint-book"] and has_ground:
				# Factorio places a blueprint as the button goes down, and again along a drag.
				_bp_mode = 2 if mb.shift_pressed and mb.ctrl_pressed else (1 if mb.shift_pressed else 0)
				_bp_axis = Vector2.ZERO
				_bp_last = blueprint_anchor(ground)
				place_blueprint(_bp_last, _bp_mode)
			elif mb.shift_pressed and cursor_item == "" and _selected_entity() != null:
				_paste_settings(_selected_entity(), false)
				_paste_dragging = true
				_lmb_down = false
			elif cursor_tool == "" and hovered != null and hud.ui.model.is_module(cursor_item):
				if _accepts_modules(hovered):
					_module_click(hovered)
				elif _openable(hovered):
					_open(hovered)
				_lmb_down = false
			elif cursor_tool == "" and hovered == null and hud.ui.model.is_module(cursor_item) and _open_mover():
				_lmb_down = false
			elif (cursor_item == "" or not _cursor_is_buildable()) and hovered != null and _openable(hovered):
				_open(hovered)
				_lmb_down = false
			elif (cursor_item == "" or not _cursor_is_buildable()) and hovered == null and _open_mover():
				_lmb_down = false
			elif _try_click_open_held(mb):
				_lmb_down = false


## A module clicked on a building or ghost (F6), as in Factorio 2.x: the mod puts it in from the
## inventory within reach, and otherwise (remote view, a ghost, out of reach, none left) asks for it:
## the robots, or a platform's hub, bring it. The mod says why when it can't.
func _module_click(r: WorldMirror.Rec) -> void:
	hud.ui.model.request_module({"u": r.unit, "p": r.proto_id, "x": r.fixed.x, "y": r.fixed.y}, cursor_item, cursor_quality)


## Alt+click: Factoriopedia's page of the entity under the mouse (a ghost's: what it will build), or
## a train or vehicle.
func _open_pedia() -> bool:
	alt_clicked()
	var proto: ProtoDB.EntityProto = null
	if hovered != null:
		proto = world.protos.entity(hovered.proto_id)
		if proto != null and proto.type == "entity-ghost" and hovered.extra.has("gh"):
			proto = world.protos.entity(int(hovered.extra["gh"]))
	elif not hovered_mover.is_empty():
		proto = world.protos.entity(int(hovered_mover[1]))
	if proto == null:
		return false
	hud.ui.open_pedia("entity", proto.name)
	return true


## An Alt+click happened: letting go of Alt then doesn't toggle Alt-mode.
func alt_clicked() -> void:
	_alt_clicked = true


## Releases are watched everywhere, so letting go over the HUD still stops mining.
func _input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		_rmb_down = false
		if _reverse_from != Vector2.INF and has_ground and cursor_item == "upgrade-planner":
			_use_planner(false, true)
		elif _reverse_from != Vector2.INF and has_ground and cursor_tool == "spidertron":
			spider_remote.right(movers, _reverse_from, ground)
		_reverse_from = Vector2.INF
	elif mb.button_index == MOUSE_BUTTON_LEFT:
		drag.end()
		capsule_aim.release()
		# Letting go of a drag from a rail end builds the path to here.
		if _lmb_down and _rail_click and has_ground and not rail_planner.path.is_empty() and _drag_from.distance_to(ground) > 2.0:
			rail_planner.build(cursor_item, _lmb_shift or hud.count_of(cursor_item) == 0 or hud.ui.remote)
		_rail_click = false
		if _lmb_down and has_ground:
			if cursor_tool in ["copy", "cut", "blueprint", "decon"]:
				_use_tool(Input.is_key_pressed(KEY_SHIFT))
			elif cursor_tool == "spidertron":
				var said := spider_remote.left(movers, _drag_from, ground, Input.is_key_pressed(KEY_SHIFT))
				if said != "":
					hud.show_message(said)
			elif cursor_tool in ["artillery", "discharge"]:
				# The remote's capsule action (mod capsules.lua): a flare at the click, or the equipment's discharge.
				Bridge.send({"t": "throw", "item": str(TOOLS[cursor_tool]), "x": int(ground.x * 256.0), "y": int(ground.y * 256.0)})
			elif cursor_tool == "" and cursor_item in ["deconstruction-planner", "upgrade-planner"]:
				_use_planner(Input.is_key_pressed(KEY_SHIFT))
		_lmb_down = false
		_paste_dragging = false
		_paste_target_key = null
		_bp_last = Vector2.INF


func _process(delta: float) -> void:
	var tilt := Input.get_axis("camera_tilt_down", "camera_tilt_up")
	if tilt != 0.0:
		rig.tilt(tilt * 60.0 * delta)
	rig.set_cursor_needed(hud.ui.is_open() or hud.ui.map_open() or hud.ui.debug_menu.is_open())
	if not Bridge.connected:
		return
	_update_ground()
	_update_walk(delta)
	_update_mining(delta)
	_update_pickup(delta)
	_update_drop(delta)
	_update_shooting(delta)
	_update_repair(delta)
	_update_building(delta)
	_update_blueprint_drag()
	_update_drag_clicks()
	var t0 := Time.get_ticks_usec()
	_update_highlights()
	world._prof("in_highlights", t0)  # (--stutter-probe: Input's 12-53 ms frames, client-cpu.md 8)
	wire_tool.update(cursor_tool, hovered, ground, has_ground)
	hud.ui.cursor.over_world_too = true if cursor_icon_world else not (_ghost.visible or _ghost_model.visible)
	if _rail_from != Vector2.INF and Bridge.world_ready and cursor_item != "" and rail_planner.click(cursor_item, _rail_from, false):
		_rail_from = Vector2.INF
	if _open_name_on_start != "" and Bridge.world_ready:
		_open_on_start = _nearest_named(_open_name_on_start)
		if _open_on_start != 0:
			_open_name_on_start = ""
	if _open_on_start != 0 and Bridge.world_ready and world.entities.has(_open_on_start):
		_open(world.entities[_open_on_start])
		_open_on_start = 0
	elif _open_on_start != 0 and Bridge.world_ready and movers != null and movers.position_of(_open_on_start) != null:
		# A train carriage or a car (a mover): the mod finds it by unit near that point.
		var at: Vector3 = movers.position_of(_open_on_start)
		_request_open(_open_on_start, {"t": "open", "u": _open_on_start, "p": 0, "x": int(at.x * 256.0), "y": int(at.z * 256.0)})
		_open_on_start = 0
	if avatar != null and avatar.vehicle != 0:
		var kmh := roundi(absf(avatar.vehicle_speed))
		hud.cursor_label.text = "%d km/h · WASD drive · Enter: get out" % kmh
	elif cursor_tool == "" and not tile_brush.use_of(cursor_item).is_empty():
		hud.cursor_label.text = "Tile area %d × %d · Numpad + / -: size · Right click: mine tiles" % [tile_brush.size, tile_brush.size]
	elif cursor_tool == "" and not rail_planner.use_of(cursor_item).is_empty():
		if rail_planner.anchor.is_empty():
			hud.cursor_label.text = "Click a rail end to plan from it · %s: rail layer" % Controls.keys_text("toggle_rail_layer")
		else:
			hud.cursor_label.text = "%d rails · Click: build · Right click: let go%s" % [rail_planner.rails_needed(),
				" · elevated" if rail_planner.target_layer == 1 else ""]
	elif cursor_tool != "":
		hud.cursor_label.text = TOOL_HINTS.get(cursor_tool, "")
	elif cursor_quality != "normal" and cursor_item != "":
		hud.cursor_label.text = "Quality: %s · Ctrl+wheel: change" % cursor_quality.capitalize()
	elif cursor_item == "deconstruction-planner" or cursor_item == "upgrade-planner":
		hud.cursor_label.text = "Drag to mark · Shift+drag: cancel · Right click the planner in the inventory: its settings"
	elif cursor_item == "blueprint-book":
		hud.cursor_label.text = "Click to place the active blueprint · Shift+wheel: pages"
	else:
		hud.cursor_label.text = _build_refusal


func _update_ground() -> void:
	over_gui = hud.ui.mouse_over_gui() and not rig.aims_center()
	var screen := _aim_screen()
	var p = rig.ground_point(screen)
	has_ground = p != null and not over_gui
	if has_ground:
		ground = Vector2(p.x, p.z)
	# Timed under --stutter-probe (world.prof, w_in_*): what under the mouse took Input's slow frames.
	var t0 := Time.get_ticks_usec()
	_aim_from(screen, p)
	# Non-buildable items and held modules pick entities under the mouse so clicking opens (or inserts modules).
	var picks := cursor_item == "" or not _cursor_is_buildable() or (cursor_tool == "" and hud.ui.model.is_module(cursor_item))
	hovered = _cursor_pick() if has_ground and picks and not _clean_shot else null
	world._prof("in_pick", t0)
	t0 = Time.get_ticks_usec()
	hovered_mover = []
	# In 3D (1st and 3rd person) a vehicle/rolling stock wins unless a foreground non-rail/non-ground entity is closer.
	if mover_pick_3d:
		if picks:
			hovered_mover = _nearer_than_aim(_mover_under_mouse())
	elif hovered == null or not _openable(hovered) or _ground_entity(hovered) or not _aim.is_empty():
		hovered_mover = _nearer_than_aim(_mover_under_mouse())
	if not hovered_mover.is_empty():
		hovered = null
		if (rig.aims_center() and fp_pick_models) or (mover_pick_3d and not has_ground and (not rig.aims_center() or fp_pick_models)):
			# The cursor on the vehicle looked at, even looking level (no ground under the aim).
			ground = hovered_mover[3]
			has_ground = true
	world._prof("in_mover", t0)
	t0 = Time.get_ticks_usec()
	var now_usec := t0
	var dt_s := float(now_usec - _last_hover_usec) / 1e6 if _last_hover_usec > 0 else 0.0
	_last_hover_usec = now_usec
	var cam_dir := rig.camera.global_basis.z if rig != null and rig.camera != null else Vector3.ZERO
	var hover_fast := false
	if dt_s > 0.0005 and dt_s < 0.25:
		if _last_cam_dir != Vector3.ZERO and cam_dir != Vector3.ZERO:
			if cam_dir.angle_to(_last_cam_dir) / dt_s > HOVER_FAST_TURN:
				hover_fast = true
		if not hover_fast and rig != null and not rig.aims_center() and _last_hover_screen.is_finite():
			if screen.distance_to(_last_hover_screen) / dt_s > HOVER_FAST_MOUSE:
				hover_fast = true
	_last_cam_dir = cam_dir
	_last_hover_screen = screen if rig != null and not rig.aims_center() else Vector2.INF
	var focus_now: Vector2 = world.focus() if world != null else Vector2.INF
	var running := dt_s > 0.0005 and dt_s < 0.25 and _last_hover_focus.is_finite() and focus_now.is_finite() \
		and focus_now.distance_to(_last_hover_focus) / dt_s > HOVER_RUN_SPEED
	_last_hover_focus = focus_now
	hud.ui.set_selected(_selected_entity(), hover_fast, running)
	world._prof("in_panel", t0)


## First person (K7): the entity the crosshair's ray meets before the ground (within AIM_RANGE) puts
## the cursor on it. `ground` moves inside its selection box, where the ray met it, so what picks
## there (the hover, mining and the bridge's sweep, Ctrl+click, Z, the wire tools) has that entity
## and not the ground behind or under it; building goes against the face looked at (build_point).
## `p` is the ray's ground point, or null (looking level or up).
func _aim_from(screen: Vector2, p) -> void:
	_aim = []
	_aim_ground = Vector2.INF
	if rig == null or not rig.aims_center() or not fp_pick_models or over_gui or _clean_shot:
		return
	var r := rig.ray(screen)
	var from: Vector3 = r[0]
	# An add-on's camera modifier (1.7) moves the eye: the reach is cut by as much, never grown.
	var limit := AIM_RANGE - rig.modifier_reach()
	if p != null:
		limit = minf(limit, from.distance_to(Vector3(p.x, GroundHeight.at(p.x, p.z), p.z)))
	_aim = AimPick.pick(world, from, r[1], limit)
	if _aim.is_empty():
		return
	var rect: Rect2 = _aim[4]
	var at: Vector3 = _aim[2]
	var inset := minf(0.05, minf(rect.size.x, rect.size.y) * 0.25)
	ground = Vector2(clampf(at.x, rect.position.x + inset, rect.end.x - inset), clampf(at.z, rect.position.y + inset, rect.end.y - inset))
	has_ground = true
	_aim_ground = ground


## Where the player aims on screen: the middle in first person or under an add-on's camera aiming at
## the centre (rig.aims_center, 1.7), else the mouse (as the UI sees it).
func _aim_screen() -> Vector2:
	return rig.aim_position() if rig.aims_center() else hud.ui.mouse_position()


## The entity the cursor is on: in first person the one the crosshair's ray met (K7), else the one
## under the ground point (world.gd pick()).
func _cursor_pick() -> WorldMirror.Rec:
	if not _aim.is_empty() and ground == _aim_ground:
		var r: WorldMirror.Rec = _aim[0]
		if world.entities.get(r.key) == r:
			return r
	return world.pick(ground)


## Where the held entity is built: the cursor's ground point; in first person with the crosshair on
## the side of something (K7), just out from that face, as far as the held entity reaches that way,
## so it goes beside what is looked at (as games place against a face). On a top (a belt, the
## ground) it stays where the ray met it: fast-replace there, or red over what is in the way.
func build_point() -> Vector2:
	if _aim.is_empty() or ground != _aim_ground:
		return ground
	var n: Vector3 = _aim[3]
	if absf(n.y) > 0.5:
		return ground
	var proto: ProtoDB.EntityProto = world.protos.placed_entity(cursor_item) if cursor_item != "" else null
	var size := Vector2i.ONE if proto == null else proto.tile_size
	if build_dir == 4 or build_dir == 12:
		size = Vector2i(size.y, size.x)
	var at: Vector3 = _aim[2]
	var half := (size.x if absf(n.x) > 0.5 else size.y) * 0.5
	return Vector2(at.x, at.z) + Vector2(n.x, n.z) * half


## A mover the mouse's ray hit (MoverLayer.pick_ray), or [] when a foreground 3D world entity
## stands in front of it along the view ray.
func _nearer_than_aim(m: Array) -> Array:
	if m.is_empty() or m.size() <= 6:
		return m
	var dist := float(m[6])
	if not _aim.is_empty():
		var aim_rec: WorldMirror.Rec = _aim[0]
		if not (mover_pick_3d and _is_rail_or_ground(aim_rec)) and dist > float(_aim[1]):
			return []
		return m
	if mover_pick_3d and rig != null and world != null and not (rig.aims_center() and fp_pick_models):
		var screen := _aim_screen()
		var r := rig.ray(screen)
		var ray_from: Vector3 = r[0]
		var ray_dir: Vector3 = r[1]
		var hit := AimPick.pick(world, ray_from, ray_dir, dist)
		if not hit.is_empty():
			var hit_rec: WorldMirror.Rec = hit[0]
			if not _is_rail_or_ground(hit_rec) and dist > float(hit[1]) + 0.05:
				return []
	return m


func _update_walk(delta: float) -> void:
	if avatar != null and avatar.vehicle != 0:
		_update_drive(delta)
		return
	_drive_code = 0
	# WASD moves the map while it is open, not the character; the console takes the keys too.
	var input := Vector2.ZERO if hud.ui.map_open() or hud.ui.typing() else Input.get_vector("move_left", "move_right", "move_down", "move_up")
	if hud.ui.remote:  # remote view: WASD moves the view
		var pan := rig.ground_right() * input.x + rig.ground_forward() * input.y
		hud.ui.pan_remote(Vector2(pan.x, pan.z) * 40.0 * delta * (3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0))
		input = Vector2.ZERO
	if input.length() <= 0.2 and not (hud.ui.map_open() or hud.ui.typing() or hud.ui.remote):
		input = _stick()
	var dir := -1
	var turn := -1
	if input.length() > 0.2:
		var world_dir := rig.ground_right() * input.x + rig.ground_forward() * input.y
		var angle := atan2(world_dir.x, -world_dir.z)  # clockwise from north
		dir = posmod(int(round(angle / (TAU / 8.0))), 8) * 2
		# B7: any angle, in thousandths of a turn; the mod steps between Factorio's 8 ways to follow it.
		turn = posmod(int(round(angle / TAU * 1000.0)), 1000)
	_walk_timer -= delta
	var turned := turn >= 0 and _walk_turn >= 0 and absi(posmod(turn - _walk_turn + 500, 1000) - 500) >= TURN_STEP
	if dir != _walk_dir or turned or (turn >= 0) != (_walk_turn >= 0) or (dir >= 0 and _walk_timer <= 0.0):
		Bridge.send({"t": "walk", "d": dir, "a": turn} if turn >= 0 else {"t": "walk", "d": dir})
		_walk_dir = dir
		_walk_turn = turn
		_walk_timer = REPEAT


## A gamepad's left stick, as the move actions' vector (up positive), or zero.
func _stick() -> Vector2:
	var pads = joypads_for_test
	if pads == null:
		pads = []
		for pad in Input.get_connected_joypads():
			pads.append({"id": pad, "known": Input.is_joy_known(pad),
				"v": Vector2(Input.get_joy_axis(pad, JOY_AXIS_LEFT_X), -Input.get_joy_axis(pad, JOY_AXIS_LEFT_Y))})
	return stick_of(pads, _sticks_centred)


## The stick that walks among `pads` ([{id, known, v}]), or zero. Only a pad Godot maps as a
## gamepad (Input.is_joy_known): an unknown device's first two axes aren't a stick. The owner's
## Thrustmaster sim pedals are one, resting at -1, and walked the character off (due west on
## Zenith Test, 2,500 tiles in 140 s) for as long as the client ran. And only once its
## stick was seen centred since it was plugged in (`centred`, kept by the caller), so a mapped
## device resting off centre doesn't walk either.
static func stick_of(pads: Array, centred: Dictionary) -> Vector2:
	var out := Vector2.ZERO
	var present := {}
	for pad in pads:
		present[pad.id] = true
		var v: Vector2 = pad.v
		if not pad.known:
			continue
		if v.length() <= STICK_DEAD_ZONE:
			centred[pad.id] = true
		elif centred.has(pad.id) and out == Vector2.ZERO:
			out = v
	for id in centred.keys():
		if not present.has(id):
			centred.erase(id)  # unplugged: whatever comes in under its id starts unseen
	return out


## In a vehicle W and S accelerate and reverse, A and D steer, relative to the vehicle as in
## Factorio, not the camera.
func _update_drive(delta: float) -> void:
	_walk_dir = -2  # walking resumes with a fresh command after getting out
	var a := 0
	var forward := 0.0 if hud.ui.typing() else Input.get_axis("move_down", "move_up")
	if forward > 0.2:
		a = 1
	elif forward < -0.2:
		a = 3
	var s := 0
	var steer := 0.0 if hud.ui.typing() else Input.get_axis("move_left", "move_right")
	if steer > 0.2:
		s = 1
	elif steer < -0.2:
		s = -1
	var code := a * 3 + s
	_walk_timer -= delta
	if code != _drive_code or (code != 0 and _walk_timer <= 0.0):
		var msg := {"t": "drive", "a": a, "s": s}
		if Settings.vehicle_brake_hold():
			msg["h"] = 1  # the mod brakes to a stop against the motion and holds there (driving.lua)
		Bridge.send(msg)
		_drive_code = code
		_walk_timer = REPEAT


func _update_mining(delta: float) -> void:
	# The entity being mined went away: it was mined, so undo can put a ghost back.
	if _mine_target != null and not world.entities.has(_mine_target.key):
		var proto: ProtoDB.EntityProto = world.protos.entity(_mine_target.proto_id)
		var item := item_for(_mine_target)
		if proto != null and item != "" and proto.type != "resource" and _mine_target.unit > 0:
			_remember({"do": "mine", "item": item, "x": _mine_target.pos.x, "y": _mine_target.pos.y, "d": _mine_target.dir})
		_mine_target = null
	if not _rmb_down:
		_remote_marked = null
		_remote_marked_mover = 0
		_mine_key = null
		if _mining:
			Bridge.send({"t": "mine_stop"})
			_mining = false
			_mine_target = null
		if avatar != null:
			avatar.mine_hint_clear()
		_reach_refused_key = null
		_refused_protos.clear()
		return
	if not tile_brush.use_of(cursor_item).is_empty() and cursor_tool == "":
		# A tile in hand: the right button mines the placed tiles under the brush, as in Factorio.
		if has_ground and not hud.ui.remote:
			tile_brush.mine(ground, delta)
		return
	_mine_timer -= delta
	# Ghosts go at once, as in Factorio (I6): one under the mouse is hidden here this frame and the
	# mod removes it on its next tick (its `del` confirms; predicted.gd shows it again if none
	# comes), and the next ghost the drag crosses doesn't wait for the repeat.
	if has_ground and not hud.ui.remote:
		var g: WorldMirror.Rec = _cursor_pick()
		if g != null and (g.extra.has("gh") or g.extra.has("tg")) and _in_reach(g.pos, Vector2i.ONE):
			if predicted != null:
				predicted.remove_ghost(g)
			Bridge.send({"t": "mine", "u": g.unit, "p": g.proto_id, "x": g.fixed.x, "y": g.fixed.y})
			_mining = true
			_mine_target = null  # a ghost mined is no building to undo
			_mine_timer = REPEAT
			return
		# J18: an item lying on the ground goes the same way (its mining time is a tick or two), over
		# ore but under belts and buildings, as Factorio's selection priorities have it.
		if (g == null or _is_resource(g)) and _take_ground_item():
			return
	# Issue #10: a train or car stands over rails and ground the world's pick would find instead, so
	# the vehicle under the mouse comes first, as for hover, and goes by its unit number.
	var mover := _mineable_mover_under_mouse() if (has_ground or mover_pick_3d) else []
	if not has_ground and mover.is_empty():
		return
	var target: WorldMirror.Rec = _cursor_pick() if (has_ground and mover.is_empty()) else null
	# J26: what is under the mouse is looked at every frame and a new target goes at once (it waited
	# for the next repeat, so a quick sweep across a belt line left belts out); the repeat keeps the
	# button held. Factorio mines what is selected, starting again on a new target.
	var key: Variant = null
	if not mover.is_empty():
		key = "m%d" % int(mover[0])
	elif target != null:
		key = target.key
	if _mine_timer > 0.0 and typeof(key) == typeof(_mine_key) and key == _mine_key:
		return
	_mine_timer = REPEAT
	_mine_key = key
	if hud.ui.remote:
		# Remote view can't reach anything: mining marks it for deconstruction instead (Factorio 2.0).
		if not mover.is_empty():
			if _remote_marked_mover != int(mover[0]):
				_remote_marked_mover = int(mover[0])
				var c: Vector2 = mover[3]
				Bridge.send({"t": "decon", "i": 0, "x1": int((c.x - 0.1) * 256.0), "y1": int((c.y - 0.1) * 256.0),
					"x2": int((c.x + 0.1) * 256.0), "y2": int((c.y + 0.1) * 256.0), "u": int(mover[0]), "p": int(mover[1])})
			return
		if target != null and target != _remote_marked:
			_remote_marked = target
			_mark_for_deconstruction(target)
		return
	if not mover.is_empty():
		var at: Vector2i = mover[2]
		var m_pos: Vector2 = mover[3]
		Bridge.send(_with_offset({"t": "mine", "u": int(mover[0]), "p": int(mover[1]), "x": at.x, "y": at.y}, ground if has_ground else m_pos))
		_mining = true
		_mine_target = null
		_hint_swing(key, m_pos, false, int(mover[1]))
		return
	if target != null:
		Bridge.send(_with_offset({"t": "mine", "u": target.unit, "p": target.proto_id, "x": target.fixed.x, "y": target.fixed.y}))
		_mining = true
		_mine_target = target
		_hint_swing(key, target.pos, _is_resource(target), target.proto_id)
		return
	# Nothing under the mouse: where it is, so the bridge mines what the walking character brings under
	# it (J26: the cursor stays put on the screen while the view follows the character).
	var none := _with_offset({"t": "mine", "n": 1})
	if none.has("ox"):
		Bridge.send(none)
		_mining = true
		_mine_target = null


## Issue #24: the swing's hint for a `mine` just sent at `at` (prototype `proto`): given only within the
## bridge's reach and not at a target or kind it refused (MINE_REFUSALS); otherwise any hint goes, so
## nothing swings (the `mine` is still sent, and the bridge says why as Factorio does).
func _hint_swing(key: Variant, at: Vector2, resource: bool, proto: int) -> void:
	_mine_proto = proto
	if avatar == null:
		return
	if not mine_reach_check:
		avatar.mine_hint(at)
		return
	var me := _character_at()
	if _reach_refused_key != null and (typeof(key) != typeof(_reach_refused_key) or key != _reach_refused_key
			or (_refused_for_reach and (me == Vector2.INF or me.distance_to(_reach_refused_at) > REFUSED_MOVE))):
		_reach_refused_key = null
	if _reach_refused_key == null and not _refused_protos.has(proto) and mine_in_reach(at, resource):
		avatar.mine_hint(at)
	else:
		avatar.mine_hint_clear()


## How far the character may move before a target refused as out of reach is tried again (tiles).
const REFUSED_MOVE := 0.25
## Factorio 2.1's character without bonuses (base's character prototype): reach_distance 10 and
## resource_reach_distance 2.7, until the bridge's `cinfo` gives the character's own.
const MINE_REACH := 10.0
const MINE_RESOURCE_REACH := 2.7


## Within the bridge's reach for mining by hand (puppet.lua can_hand_mine): the character's
## resource_reach_distance for a resource, else its reach_distance, plus the bridge's slack, from
## the character to the target's middle. No character known: in reach (the bridge decides).
func mine_in_reach(at: Vector2, resource: bool) -> bool:
	var me := _character_at()
	if me == Vector2.INF:
		return true
	var reach := MINE_RESOURCE_REACH if resource else MINE_REACH
	if hud != null and hud.ui != null and hud.ui.model != null:
		reach = hud.ui.model.mine_reach(resource)
	return me.distance_to(at) <= reach + BRIDGE_REACH_SLACK


func _character_at() -> Vector2:
	if avatar != null:
		return avatar.ground_position()
	return character_at_for_test


## A message from the bridge (`msg`, main.gd). Issue #24: a refusal of the hand mine held
## (MINE_REFUSALS) stops the swing at once and keeps it stopped: out of reach while the button stays on
## that target and the character stands; "Can't mine that" while it stays on that target; a kind that
## needs a drill or pump for every entity of it until the button is let go.
func heard_message(text: String) -> void:
	if not mine_reach_check or not MINE_REFUSALS.has(text) or not _rmb_down or not _mining or _mine_key == null:
		return
	var what: String = MINE_REFUSALS[text]
	if what == "kind" and _mine_proto > 0:
		_refused_protos[_mine_proto] = true
	_reach_refused_key = _mine_key
	_reach_refused_at = _character_at()
	_refused_for_reach = what == "reach"
	if avatar != null:
		avatar.mine_hint_clear()


## A `mine` with the cursor's place from the character as drawn (`ox`, `oy`, 1/256 tiles), which
## the bridge's sweep follows each tick (J26: the view, and with it a still cursor, goes with the
## character; in first person the aim does). As it was without a character.
func _with_offset(cmd: Dictionary, cursor_pos: Vector2 = ground) -> Dictionary:
	var me := character_at_for_test
	if avatar != null:
		me = avatar.ground_position()
	if me == Vector2.INF:
		return cmd
	cmd["ox"] = int(roundf((cursor_pos.x - me.x) * 256.0))
	cmd["oy"] = int(roundf((cursor_pos.y - me.y) * 256.0))
	return cmd


func _is_resource(r: WorldMirror.Rec) -> bool:
	var proto: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
	return proto != null and proto.type == "resource"


## The item lying under the mouse, in reach, picked up (`mine` `gi`) and hidden at once (J18): true
## when there was one.
func _take_ground_item() -> bool:
	if ground_items == null:
		return false
	var item: Array = ground_items.item_at(ground)
	if item.is_empty():
		return false
	var at: Vector2i = item[0]
	if not _in_reach(Vector2(at) / 256.0, Vector2i.ONE) or not _mineable_mover_under_mouse().is_empty():
		return false
	Bridge.send({"t": "mine", "gi": 1, "x": at.x, "y": at.y})
	ground_items.take(at)
	_mining = true
	_mine_target = null
	return true


## Marks one entity for deconstruction (the area under its middle), as mining it in remote view does.
func _mark_for_deconstruction(target: WorldMirror.Rec) -> void:
	var c: Vector2 = target.pos
	Bridge.send({"t": "decon", "i": 0, "x1": int((c.x - 0.1) * 256.0), "y1": int((c.y - 0.1) * 256.0),
		"x2": int((c.x + 0.1) * 256.0), "y2": int((c.y + 0.1) * 256.0)})


## Holding F picks up items on the ground around the character, like in Factorio.
## Polled, so a release over the HUD (or the key going to a text box) still stops it. Exact (pickup_exact):
## Godot keeps whether the last F event matched exactly, so F pressed under Ctrl stays not picking when Ctrl
## is let go, until F is pressed again; Ctrl pressed while F is held doesn't stop it either.
func _update_pickup(delta: float) -> void:
	_pickup_timer -= delta
	var held := Input.is_action_pressed("pick_up", pickup_exact) and not hud.ui.typing()
	if held and _pickup_timer <= 0.0:
		Bridge.send({"t": "pickup"})
		_pickup_timer = REPEAT
		_pickup_held = true
	elif not held and _pickup_held:
		_pickup_held = false
		if pickup_stop:
			Bridge.send({"t": "pickup_stop"})
			_pickup_timer = 0.0  # pressed again, it picks at once


## Z drops one of the held item where the mouse is; held down it keeps dropping, like Factorio.
func _update_drop(delta: float) -> void:
	_drop_timer -= delta
	if not Input.is_action_pressed("drop_item", true) or hud.ui.typing():
		_drop_timer = 0.0
		return
	if _drop_timer > 0.0:
		return
	_drop_timer = REPEAT
	if cursor_item == "" or cursor_tool != "" or not has_ground:
		return
	if hud.ui.remote and not _in_reach(ground, Vector2i.ONE):
		hud.show_message("Out of reach")  # the mod refuses; no predicted item on a belt far away
		return
	var cmd := {"t": "drop", "item": cursor_item, "x": int(ground.x * 256.0), "y": int(ground.y * 256.0)}
	# L7: out of the held stack's own slot, as Factorio drops from the cursor (not another stack of it).
	var hs: int = hud.ui.build_slot()
	if hs > 0:
		cmd["hs"] = hs
	Bridge.send(cmd)
	if belt_items != null and world != null:
		belt_items.predict_drop(world.protos.item_id(cursor_item), ground.x, ground.y)


## Like Factorio: Space shoots at enemies near the character (the game picks the target), Shift+Space
## (1.1's C) at whatever is under the cursor. Both with exactly their modifiers: Shift+Space never
## shoots at enemies, even where it can't shoot at the cursor (a screen open, no ground).
func _update_shooting(delta: float) -> void:
	var mode := -1
	if not hud.ui.typing():
		if Input.is_action_pressed("shoot_cursor", true) and has_ground and not hud.ui.is_open():
			mode = 1
		elif Input.is_action_pressed("shoot_enemies", true):
			mode = 0
	if combat != null:
		combat.aim_mode = mode
		combat.aim = ground
	_shoot_timer -= delta
	if mode != _shoot_mode or (mode >= 0 and _shoot_timer <= 0.0):
		Bridge.send({"t": "shoot", "m": mode, "x": int(ground.x * 256.0), "y": int(ground.y * 256.0)})
		_shoot_mode = mode
		_shoot_timer = REPEAT


## K13: the left button held with a repair tool in the hand repairs the building under the mouse, as in
## Factorio: `repair` for it, again every REPEAT while the button stays on it (the bridge holds a command
## 30 ticks) and at once when the mouse comes onto another; `repair` without a target as the button lets
## go or the mouse leaves it. The bridge decides what may be mended (damaged, the character's force, in
## reach) and mends it at the pack's speed; the health bar rises from its `hp`.
## N4: vehicles and wagons too, as Factorio mends them: they are movers, not the world's records, so
## they are picked by their own box (MoverLayer.pick_ray, which hovered_mover skips with an item held)
## and win over the rail or ground under them.
func _update_repair(delta: float) -> void:
	var unit := 0
	var proto_id := 0
	var at := Vector2i.ZERO
	if _lmb_down and cursor_tool == "" and (has_ground or mover_pick_3d) and not hud.ui.remote and hud.ui.model.is_repair_tool(cursor_item):
		var m := _repairable_mover_under_mouse()
		if not m.is_empty():
			unit = int(m[0])
			proto_id = int(m[1])
			at = m[2]
		elif has_ground:
			var target: WorldMirror.Rec = _cursor_pick()
			if target != null and target.unit > 0:
				unit = target.unit
				proto_id = target.proto_id
				at = target.fixed
	if unit <= 0:
		if repair_unit != 0:
			repair_unit = 0
			Bridge.send({"t": "repair"})
		return
	_repair_timer -= delta
	if unit == repair_unit and _repair_timer > 0.0:
		return
	repair_unit = unit
	_repair_timer = REPEAT
	var cmd := {"t": "repair", "u": unit, "p": proto_id, "x": at.x, "y": at.y, "item": cursor_item}
	if cursor_quality != "normal":
		cmd["q"] = cursor_quality
	var hs: int = hud.ui.build_slot()
	if hs > 0:
		cmd["hs"] = hs  # the held stack's own slot: its packs are used first, as the hand's
	Bridge.send(cmd)


func _next_gun() -> void:
	var n := hud.guns.size()
	for step in range(1, n + 1):
		var i := posmod(hud.selected_gun - 1 + step, n)
		var slot = hud.guns[i]
		# Factorio only switches to a weapon that has ammo ("the weapon to change to must have ammo").
		if slot is Array and slot.size() >= 3 and str(slot[0]) != "" and int(slot[2]) > 0:
			if i + 1 != hud.selected_gun:
				Bridge.send({"t": "gun", "i": i + 1})
			return


## A planner used on release, over the dragged area (Shift: cancel the marks; an upgrade planner's
## right-drag: downgrade).
func _use_planner(cancel: bool, reverse := false) -> void:
	var slot := planner_slot()
	if slot == 0:
		hud.show_message("You have no %s" % cursor_item)
		return
	var at := ground * 256.0
	var from := (_reverse_from if reverse else _drag_from) * 256.0
	var cmd := {"t": "decon" if cursor_item == "deconstruction-planner" else "upgrade", "i": slot,
		"x1": int(from.x), "y1": int(from.y), "x2": int(at.x), "y2": int(at.y), "cancel": 1 if cancel else 0}
	if reverse:
		cmd["down"] = 1
	Bridge.send(cmd)


## Places the held blueprint (a book: its active page) centred at `at`: mode 0 normal (a click), 1
## forced (Shift), 2 super-forced (Ctrl+Shift), Factorio's build modes.
func place_blueprint(at: Vector2, mode: int) -> void:
	var slot := planner_slot()
	if slot == 0:
		hud.show_message("You have no %s" % cursor_item)
		return
	var cmd := {"t": "blueprint", "i": slot, "x": roundi(at.x * 256.0), "y": roundi(at.y * 256.0), "d": build_dir, "bm": mode}
	if mode == 2:
		cmd["sf"] = 1
	if build_mirror:
		cmd["m"] = 1  # H / V: the mod places a mirrored copy (V is this turned half way round)
	Bridge.send(cmd)


## Where the held blueprint goes for the mouse at `at`, as the mod is told: its middle where the
## mouse is, moved as little as puts its entities on the tile grid (the clipboard's rule, #21: Factorio
## pastes there, and a middle already on the grid stays where it is sent; the preview is drawn
## there), or with absolute snap to grid on its grid (the world's grid, moved by its offset; the
## preview then from blueprint_preview_centre).
func blueprint_anchor(at: Vector2) -> Vector2:
	var snap: Dictionary = hud.ui.planners.held_snap()
	if not snap.is_empty() and bool(snap.get("absolute", false)):
		var grid: Vector2 = snap["grid"]
		var offset: Vector2 = snap["offset"]
		var cell := ((at - offset) / grid).floor() * grid + offset
		return cell + (grid * 0.5).round()
	var entries: Array = hud.ui.planners.held_preview(world.protos)
	if not entries.is_empty():
		return _paste_centre_at(at, entries[0], build_dir / 4)
	var tiles: Array = hud.ui.planners.held_preview_tiles()
	if not tiles.is_empty():
		# Tiles alone: the first one's middle on a tile's middle.
		var first := (tiles[0] as Vector2) + Vector2(0.5, 0.5)
		for t in build_dir / 4:
			first = Vector2(-first.y, first.x)
		var on := at + first
		return Vector2(floorf(on.x) + 0.5, floorf(on.y) + 0.5) - first
	return Vector2(roundf(at.x), roundf(at.y))


## Where the held blueprint's preview has its middle for the mouse at `at`: blueprint_anchor, and with
## absolute snapping where its entities were drawn round that anchor before K11 (held_shift).
func blueprint_preview_centre(at: Vector2) -> Vector2:
	var snap: Dictionary = hud.ui.planners.held_snap()
	if not snap.is_empty() and bool(snap.get("absolute", false)):
		return blueprint_anchor(at) + hud.ui.planners.held_shift()
	return blueprint_anchor(at)


## Dragging with a blueprint: placed again every step along the drag's axis, as Factorio does.
func _update_blueprint_drag() -> void:
	if _bp_last == Vector2.INF or not _lmb_down or not has_ground or not (cursor_item in ["blueprint", "blueprint-book"]):
		return
	var step := Vector2(hud.ui.planners.held_step(world.protos, build_dir))
	if step.x <= 0 or step.y <= 0:
		return
	var d := ground - _bp_last
	if _bp_axis == Vector2.ZERO:
		if absf(d.x) >= step.x * 0.5 or absf(d.y) >= step.y * 0.5:
			_bp_axis = Vector2(signf(d.x), 0) if absf(d.x) / step.x >= absf(d.y) / step.y else Vector2(0, signf(d.y))
		else:
			return
	var along := d.dot(_bp_axis)
	var length := absf(step.dot(_bp_axis))
	var placed := 0
	while along >= length * 0.5 and placed < 8:
		_bp_last += _bp_axis * length
		place_blueprint(_bp_last, _bp_mode)
		along -= length
		placed += 1


## The shortcut tools, used over the dragged area: copy or cut it to the clipboard (then paste it),
## make a blueprint of it in the inventory, or mark it for deconstruction (Shift: unmark).
func _use_tool(cancel: bool) -> void:
	var a := _drag_from * 256.0
	var b := ground * 256.0
	var area := {"x1": int(a.x), "y1": int(a.y), "x2": int(b.x), "y2": int(b.y)}
	match cursor_tool:
		"decon":
			var cmd := {"t": "decon", "i": 0, "cancel": 1 if cancel else 0}
			cmd.merge(area)
			Bridge.send(cmd)
		"copy", "cut", "blueprint":
			var cmd := {"t": "copy", "cut": 1 if cursor_tool == "cut" else 0, "bp": 1 if cursor_tool == "blueprint" else 0}
			cmd.merge(area)
			if cursor_tool == "blueprint" and reselect_slot != 0:
				cmd["to"] = reselect_slot
			Bridge.send(cmd)
			if cursor_tool == "blueprint":
				hold("")
			else:
				build_dir = 0
				hold_tool("paste")  # the clipboard arrives as `clip`; until then nothing is drawn


## Ctrl+V or after a copy: the clipboard's ghosts, centred where the mouse is.
func _paste() -> void:
	if not has_ground or hud.ui.model.clipboard.is_empty():
		return
	# Rounded down as every build point (J9): the mod snaps it, so cut towards zero a point just
	# under a tile's edge at negative coordinates pasted a tile over.
	Bridge.send({"t": "paste", "x": wire(ground.x), "y": wire(ground.y), "d": build_dir})


## The stack of the held blueprint or planner: the library's (-1), the one picked up from the
## inventory, or the first of its item; 0 for none.
func planner_slot() -> int:
	if cursor_slot != 0:
		return cursor_slot
	if not hud.ui.hand.is_empty() and hud.ui.hand["role"] == "main":
		return int(hud.ui.hand["index"])
	return _slot_of(cursor_item)


## The first main inventory slot (1-based) holding an item, from the mod's `slots`; 0 if none.
func _slot_of(item: String) -> int:
	var slots: Array = hud.ui.model.main_slots
	for i in slots.size():
		var s: Dictionary = slots[i]
		if s.get("item", "") == item:
			return i + 1
	return 0


func _update_building(delta := 0.0) -> void:
	if not _lmb_down or cursor_item == "" or cursor_tool != "" or not has_ground or PLANNERS.has(cursor_item):
		return
	# Shift+click, or nothing left of it (the pipette's ghost cursor): a ghost for the robots. In
	# remote view everything placed is a ghost, as in Factorio 2.0 (the mod wants charted ground).
	var ghost := _lmb_shift or hud.count_of(cursor_item) == 0 or hud.ui.remote
	if not tile_brush.use_of(cursor_item).is_empty():
		tile_brush.paint(cursor_item, ground, ghost, delta)
		return
	if not capsule_aim.use_of(cursor_item).is_empty():
		if not hud.ui.remote:
			capsule_aim.hold(cursor_item, ground, delta)
		return
	if _rail_click:
		return  # the rail planner's click: the path is built on release
	if world.protos.placed_entity(cursor_item) == null or not hud.ui.can_build_from_hand():
		return
	# Holding the button builds along the way, as Factorio drags (drag_build.gd).
	if not drag.active():
		drag.begin(cursor_item, world.protos.placed_entity(cursor_item), build_point(), ghost)
	else:
		drag.update(build_point(), DragBuild.MAX_STEPS_PER_FRAME)


func _rotate(reverse: bool) -> void:
	if cursor_tool == "" and not tile_brush.use_of(cursor_item).is_empty():
		if str(tile_brush.use_of(cursor_item)[1]) != "":
			tile_brush.alt = not tile_brush.alt  # hazard concrete: the stripes the other way
		return
	if cursor_tool == "paste":
		build_dir = posmod(build_dir + (-4 if reverse else 4), 16)
	elif cursor_item != "" and drag.active() and has_ground and drag.rotate(reverse, build_point()):
		pass  # J25: R while dragging belts bends the line towards the cursor (drag_build.gd)
	elif cursor_item != "" and (world.protos.placed_entity(cursor_item) != null or PLANNERS.has(cursor_item)):
		var proto: ProtoDB.EntityProto = world.protos.placed_entity(cursor_item)
		if proto != null:
			if RailBlocks.is_rail_attachment(proto.type) or NON_ROTATABLE_TYPES.has(proto.type):
				return
			var px := _xprops(proto)
			var vt := VisualTurns.eligible(proto, px)
			if (proto.type == "assembling-machine" or proto.type == "furnace") and not vt and px.has("fo"):
				return
			if proto.type == "storage-tank":
				build_dir = 0 if posmod(build_dir, 8) == 4 else 4
				return
		# Rails also go diagonally.
		var step := 2 if proto != null and proto.type == "straight-rail" else 4
		build_dir = posmod(build_dir + (-step if reverse else step), 16)
	elif hovered != null:
		# Nothing that builds in the cursor (or an item that doesn't, like a plate): R turns the
		# entity under the mouse, as in Factorio. Shown turned at once (predicted.gd) where the game
		# always turns it; the game's answer replaces it.
		var eff_id: int = hovered.proto_id
		var proto: ProtoDB.EntityProto = world.protos.entity(eff_id)
		if proto != null and proto.type == "entity-ghost" and hovered.extra.has("gh"):
			eff_id = int(hovered.extra["gh"])
			proto = world.protos.entity(eff_id)
		var x: Dictionary = hud.ui.model.eprops.get(eff_id, {}).get("x", {})
		if hovered.unit > 0 and VisualTurns.eligible(proto, x):
			# One Factorio can't turn (a furnace, a chest, a 360-degree turret, or their ghosts):
			# turned for the look in Zenith only, kept for this save until mined (I9, visual_turns.gd).
			VisualTurns.turn(Bridge.save_id, hovered.unit, reverse)
			hovered.dir = posmod(hovered.dir + (-4 if reverse else 4), 16)
			world.record_edited(hovered)
			return
		if predicted != null and not hud.ui.remote:
			# J23: an underground belt's other end turns with it, as Factorio turns a pair (both swap
			# entrance and exit); found before the turn changes which way this one looks.
			var other: WorldMirror.Rec = null
			if proto != null and proto.type == "underground-belt":
				other = UndergroundPairs.partner(world, hovered, _under_reach(proto))
			predicted.turn(hovered, reverse)
			if other != null:
				predicted.turn(other, reverse)
		Bridge.send({"t": "rotate", "u": hovered.unit, "p": hovered.proto_id, "x": hovered.fixed.x, "y": hovered.fixed.y, "rev": 1 if reverse else 0})


## H / V: flips what is being built, or the entity under the mouse (Factorio 2.0 mirrors it; a
## vertical flip is a horizontal one turned half way round).
func _flip(vertical: bool) -> void:
	if cursor_item != "" and cursor_tool == "":
		build_mirror = not build_mirror
		if vertical:
			build_dir = posmod(build_dir + 8, 16)
		hud.show_message("Flipped" if build_mirror else "Not flipped")
	elif hovered != null and hovered.unit > 0:
		Bridge.send({"t": "flip", "u": hovered.unit, "p": hovered.proto_id, "x": hovered.fixed.x, "y": hovered.fixed.y, "v": 1 if vertical else 0})


## Q: with nothing held over an entity, the pipette (its item, turned the same way; a ghost cursor
## when there are none); otherwise empties the cursor.
func _pipette_or_clear() -> void:
	if cursor_item == "" and over_gui and hud.ui.slot_pipette():
		return  # over a window: the item of the slot under the mouse (factorio_ui.gd)
	# Over an entity Q is the pipette, also with something else held (that goes back first, as in
	# 2.1.23); over nothing, or over what is already held, it clears the cursor.
	var item := item_for(hovered) if hovered != null and not over_gui and cursor_tool == "" else ""
	# Issue #13: a train, wagon or vehicle under the mouse is picked too, turned its way.
	var vehicle: Array = []
	if hovered == null and not over_gui and cursor_tool == "":
		vehicle = _mineable_mover_under_mouse()
		if not vehicle.is_empty():
			item = item_for_proto(world.protos.entity(int(vehicle[1])))
	if item != "" and item != cursor_item:
		hud.ui.clear_cursor()
		hold("")
	if cursor_item == "" and item != "":
		var quality := str(hovered.extra.get("q", "normal")) if hovered != null else "normal"
		hud.ui.pick_from_inventory(item, quality if quality != "" else "normal")
		if cursor_item != item:
			hold(item)
		# Factorio's smart pipette picks the entity's own quality (a ghost's too).
		cursor_quality = quality if quality != "" else "normal"
		build_dir = hovered.dir if hovered != null else yaw_direction(float(vehicle[5]))
		if hud.count_of(item) == 0:
			hud.show_message("None in the inventory: builds ghosts")
		return
	hud.ui.clear_cursor()
	hold("")


## The item that builds an entity (its ghost's entity for a ghost), or "".
func item_for(r: WorldMirror.Rec) -> String:
	var proto: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
	if proto != null and proto.type == "entity-ghost" and r.extra.has("gh"):
		proto = world.protos.entity(int(r.extra["gh"]))
	if proto != null and proto.type == "resource":
		return ""  # ore is no building: Q over it holds nothing (its name is also the ore item's)
	return item_for_proto(proto)


## The 16-way direction nearest a mover's yaw (Visuals.orientation_yaw's inverse).
static func yaw_direction(yaw: float) -> int:
	return posmod(roundi(-yaw / TAU * 16.0), 16)


## The item that places this entity prototype, or "".
func item_for_proto(proto: ProtoDB.EntityProto) -> String:
	if proto == null:
		return ""
	if world.protos.item_names.values().has(proto.name):
		return proto.name
	for item in world.protos.item_places:
		if world.protos.item_places[item] == proto.name:
			return str(item)
	return ""


## Movers a Ctrl+click puts into or takes from (N2): Factorio's fast transfer works on every vehicle
## and wagon with an inventory (a car's fuel, ammo and trunk, a locomotive's fuel, a wagon's cargo).
const FAST_MOVERS := ["car", "spider-vehicle", "locomotive", "cargo-wagon", "artillery-wagon", "infinity-cargo-wagon"]


## What a Ctrl+click is on: the vehicle or wagon under the mouse first (N2: they are movers, not in
## the world's records, so the world's pick found the ground or rail under them and nothing was
## sent), else the entity. {key, u, p, x, y, at} or {}.
func _fast_pick() -> Dictionary:
	var m: Array = []
	if movers != null and not over_gui and not _clean_shot:
		if not hovered_mover.is_empty():
			m = hovered_mover
		elif rig != null:
			# hovered_mover stays empty while a stack is held (_mover_under_mouse), so look again.
			var screen := _aim_screen()
			var r := rig.ray(screen)
			m = _nearer_than_aim(movers.pick_ray(r[0], r[1], FAST_MOVERS))
	if not m.is_empty() and FAST_MOVERS.has(_mover_type(m)):
		var fixed: Vector2i = m[2]
		return {"key": "m%d" % int(m[0]), "u": int(m[0]), "p": int(m[1]), "x": fixed.x, "y": fixed.y, "at": m[3]}
	if not has_ground:
		return {}
	var target: WorldMirror.Rec = _cursor_pick()
	if target == null or target.unit == 0:
		return {}
	return {"key": "e%s" % str(target.key), "u": target.unit, "p": target.proto_id, "x": target.fixed.x, "y": target.fixed.y, "at": target.pos}


## Ctrl+click on an entity or vehicle: the held stack in (right: half), or its output out (right:
## half), like Factorio's fast transfer. The mod checks reach and what fits.
func _fast_transfer(half: bool) -> void:
	if not has_ground and not mover_pick_3d:
		return
	var target := _fast_pick()
	if target.is_empty():
		return
	if hud.ui.remote and not _in_reach(target["at"], Vector2i.ONE):
		# Remote view: the character's hands don't reach (the mod refuses too); no flying items or sound.
		if _fast_target != target["key"]:
			hud.show_message("Out of reach")
		_fast_target = target["key"]
		return
	var putting := cursor_item != "" and cursor_tool == ""
	if _fast_target == null:
		_fast_putting = putting  # the drag goes on as it began (see _update_drag_clicks)
	elif _fast_putting != putting:
		return  # the held stack ran out on the way: Factorio's drag doesn't start taking then
	_fast_target = target["key"]
	var cmd := {"t": "fast", "u": target["u"], "p": target["p"], "x": target["x"], "y": target["y"], "half": 1 if half else 0}
	if putting:
		cmd["item"] = cursor_item
		var n: int = hud.ui.hand_count()
		if n > 0:
			cmd["n"] = n
		if cursor_quality != "normal":
			cmd["q"] = cursor_quality
		# The held stack's own slot: the mod takes the items from it first, so the hand is what
		# empties (I1) and not another stack of the item.
		var hs: int = hud.ui.build_slot()
		if hs > 0:
			cmd["hs"] = hs
	Bridge.send(cmd)
	# The answer (the inventory changing) plays Factorio's sound and flies the items (I3, I4), and
	# an emptied hand drops the selection (I1): factorio_ui.gd.
	var at: Vector2 = target["at"]
	hud.ui.fast_transfer_sent(cursor_item if putting else "", Vector3(at.x, 0.6, at.y))


## Factorio lets Ctrl+click and Shift+click (paste settings) be dragged: holding the button with the
## key down, each further entity the mouse crosses gets the same transfer or paste once.
func _update_drag_clicks() -> void:
	if _fast_button != MOUSE_BUTTON_NONE:
		if not Input.is_mouse_button_pressed(_fast_button) or not Input.is_key_pressed(KEY_CTRL) or over_gui or (not has_ground and not mover_pick_3d):
			if not Input.is_mouse_button_pressed(_fast_button):
				_fast_button = MOUSE_BUTTON_NONE
			return
		var target := _fast_pick()
		if not target.is_empty() and target["key"] != _fast_target:
			_fast_transfer(_fast_button == MOUSE_BUTTON_RIGHT)
	if _paste_dragging:
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or not Input.is_key_pressed(KEY_SHIFT):
			_paste_dragging = false
			_paste_target_key = null
			return
		var paste_rec := _selected_entity()
		if paste_rec != null and not over_gui and (typeof(paste_rec.key) != typeof(_paste_target_key) or paste_rec.key != _paste_target_key):
			_paste_settings(paste_rec, true)


## Shift+right click: remembers the entity (or ghost, or mover) to paste its settings from.
func _copy_settings() -> void:
	var target: WorldMirror.Rec = _hovered_mover_record()
	if target == null and movers != null and rig != null and not over_gui and not _clean_shot:
		var r := rig.ray(_aim_screen())
		var m := _nearer_than_aim(movers.pick_ray(r[0], r[1], HOVER_MOVERS))
		if not m.is_empty():
			target = _mover_to_rec(m)
	if target == null and has_ground:
		target = _cursor_pick()
	if target == null or target.unit == 0:
		return
	var eff_id: int = target.proto_id
	var proto: ProtoDB.EntityProto = world.protos.entity(eff_id)
	if proto != null and proto.type == "entity-ghost" and target.extra.has("gh"):
		eff_id = int(target.extra["gh"])
		proto = world.protos.entity(eff_id)
	var x: Dictionary = (hud.ui.model.eprops.get(eff_id, {}) as Dictionary).get("x", {}) if hud != null and hud.ui != null and hud.ui.model != null else {}
	copied_settings = {
		"u": target.unit, "p": target.proto_id, "ep": eff_id, "x": target.fixed.x, "y": target.fixed.y,
		"name": proto.name if proto != null else "",
		"dir": target.dir,
		"q": VisualTurns.quarters(Bridge.save_id, target.unit),
		"vt": VisualTurns.eligible(proto, x),
	}
	Sfx.play_ui("entity-settings-copied")
	hud.show_message("Settings copied from %s" % (hud.ui.entity_name(proto.name) if proto != null else "entity"))


## Shift+left click: pastes the copied settings (recipe, filters, requests, combinator settings...)
## with LuaEntity.copy_settings, plus Zenith's visual turns for eligible non-rotatable buildings and ghosts.
func _paste_settings(target: WorldMirror.Rec, is_drag := false) -> void:
	_paste_target_key = target.key
	if copied_settings.is_empty() or target.unit == 0 or target.unit == int(copied_settings["u"]):
		return
	var target_eff_id: int = target.proto_id
	var target_proto: ProtoDB.EntityProto = world.protos.entity(target_eff_id)
	if target_proto != null and target_proto.type == "entity-ghost" and target.extra.has("gh"):
		target_eff_id = int(target.extra["gh"])
		target_proto = world.protos.entity(target_eff_id)
	if target_proto != null and NON_CONFIGURABLE_PASTE_TYPES.has(target_proto.type):
		return
	var x: Dictionary = (hud.ui.model.eprops.get(target_eff_id, {}) as Dictionary).get("x", {}) if hud != null and hud.ui != null and hud.ui.model != null else {}
	var target_vt := VisualTurns.eligible(target_proto, x)
	var vt_changed := false
	var copied_eff_id := int(copied_settings.get("ep", copied_settings.get("p", -1)))
	if target_vt and bool(copied_settings.get("vt", false)) and copied_eff_id == target_eff_id and copied_settings.has("q"):
		var q := int(copied_settings["q"])
		var old_q := VisualTurns.quarters(Bridge.save_id, target.unit)
		vt_changed = VisualTurns.set_quarters(Bridge.save_id, target.unit, q)
		if vt_changed:
			var base_dir := posmod(target.dir - 4 * old_q, 16)
			target.dir = posmod(base_dir + 4 * posmod(q, 4), 16)
			world.record_edited(target)
	if target_vt and target_proto != null and NON_PASTABLE_VT_TYPES.has(target_proto.type):
		if vt_changed:
			Sfx.play_ui("entity-settings-pasted")
		return
	var cmd := {"t": "paste_settings", "f": [copied_settings["u"], copied_settings["p"], copied_settings["x"], copied_settings["y"]],
		"u": target.unit, "p": target.proto_id, "x": target.fixed.x, "y": target.fixed.y}
	if is_drag:
		cmd["drag"] = 1
	Bridge.send(cmd)


## Ctrl+Z: takes back the newest of this client's own building (marks it for deconstruction) or
## mining (puts a ghost back), as Factorio's undo does for a player. Ctrl+Y does it again.
func undo() -> void:
	if _undo.is_empty():
		hud.show_message("Nothing to undo")
		return
	var a: Dictionary = _undo.pop_back()
	_redo.append(a)
	_reverse(a, true)


func redo() -> void:
	if _redo.is_empty():
		hud.show_message("Nothing to redo")
		return
	var a: Dictionary = _redo.pop_back()
	_undo.append(a)
	_reverse(a, false)


## Undo (back = true) or redo an action: a build is undone by a deconstruction mark and redone by
## a ghost; a mining the other way round.
func _reverse(a: Dictionary, back: bool) -> void:
	if str(a["do"]) == "mod":
		if back:
			hud.ui.model.planners.undo(int(a["h"]))
		else:
			hud.ui.model.planners.redo(int(a["h"]))
		hud.show_message(("Undo: %s" if back else "Redo: %s") % str(a["what"]).capitalize())
		return
	var at := Vector2(float(a["x"]), float(a["y"])) * 256.0
	var place: bool = (str(a["do"]) == "mine") == back
	if place:
		Bridge.send({"t": "build", "item": a["item"], "x": int(at.x), "y": int(at.y), "d": int(a["d"]), "ghost": 1})
	else:
		# nh: the mod doesn't remember this one (it is the undo itself).
		Bridge.send({"t": "decon", "i": 0, "x1": int(at.x) - 32, "y1": int(at.y) - 32, "x2": int(at.x) + 32, "y2": int(at.y) + 32,
			"cancel": 0, "nh": 1})


## The mod remembered an action (`hist`): it goes on the undo list with this client's own.
func remember_mod(h: int, what: String) -> void:
	_remember({"do": "mod", "h": h, "what": what})


## Ctrl+mouse wheel: the held item's quality, through the qualities the force has (Factorio 2.x).
func cycle_quality(step: int) -> void:
	if cursor_item == "" or cursor_tool != "" or PLANNERS.has(cursor_item):
		return
	var list: Array = hud.ui.model.planners.unlocked_qualities()
	var at := maxi(list.find(cursor_quality), 0)
	var next: String = list[clampi(at + step, 0, list.size() - 1)]
	if next != cursor_quality:
		cursor_quality = next
		hud.ui.hand_quality_changed(next)  # a held stack gives way to one of that quality (L7)
		hud.show_message("Quality: %s" % next.capitalize())


## Shift+mouse wheel with a book held: its next or previous page.
func _cycle_book(step: int) -> void:
	if cursor_item == "blueprint-book":
		hud.ui.planners.cycle_book(planner_slot(), step)


func _remember(a: Dictionary) -> void:
	_undo.append(a)
	_redo.clear()
	while _undo.size() > HISTORY:
		_undo.pop_front()


## Whether the cursor holds something that builds, plans, wires, throws, repairs, or inserts modules.
## Plain items (plates, ore, science packs, ammo, ...) return false so clicking opens buildings.
func _cursor_is_buildable() -> bool:
	if cursor_tool != "":
		return true
	if cursor_item == "":
		return false
	if PLANNERS.has(cursor_item) or WireTool.is_wire(cursor_item):
		return true
	if world != null and world.protos != null and world.protos.placed_entity(cursor_item) != null:
		return true
	if hud == null or hud.ui == null or hud.ui.model == null:
		return false
	var cap := capsule_aim.use_of(cursor_item)
	if not cap.is_empty() and str(cap[0]) != "use-on-self":
		return true
	if not tile_brush.use_of(cursor_item).is_empty() or not rail_planner.use_of(cursor_item).is_empty():
		return true
	return hud.ui.model.is_module(cursor_item) or hud.ui.model.is_repair_tool(cursor_item)


## Whether `r` (or the entity its ghost will build) can hold modules.
func _accepts_modules(r: WorldMirror.Rec) -> bool:
	if r == null or world == null or world.protos == null:
		return false
	var proto: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
	if proto == null:
		return false
	if proto.type == "entity-ghost" and r.extra.has("gh"):
		proto = world.protos.entity(int(r.extra["gh"]))
		if proto == null:
			return false
	if not MODULE_ENTITY_TYPES.has(proto.type):
		return false
	if hud != null and hud.ui != null and hud.ui.model != null and hud.ui.model.eprops.has(proto.id):
		var x: Dictionary = (hud.ui.model.eprops.get(proto.id, {}) as Dictionary).get("x", {})
		var isq: Variant = x.get("isq")
		if isq is Array:
			for row in (isq as Array):
				if row is Array and not (row as Array).is_empty() and str(row[0]) == "m":
					return true
			return false
	return true


func _openable(r: WorldMirror.Rec) -> bool:
	var proto: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
	if proto != null and proto.type == "entity-ghost" and r.extra.has("gh"):
		proto = world.protos.entity(int(r.extra["gh"]))
	# Anything on a circuit network opens to its circuit settings (a belt, a wall, a rail signal).
	return r.unit > 0 and proto != null and (OPENABLE_TYPES.has(proto.type) or r.extra.has("r") or r.extra.has("g"))


## Effective placement/preview direction for `proto`: prevents non-rotatable buildings and x.fo
## assemblers/furnaces without fluid recipes from showing a rotated angle that Factorio will ignore
## when placed (C3), allows VisualTurns buildings in both real and ghost mode, and clamps storage tanks to 0/4.
func effective_build_dir(proto: ProtoDB.EntityProto, _ghost_mode: bool) -> int:
	if proto == null:
		return 0
	if RailBlocks.is_rail_attachment(proto.type):
		return build_dir
	if NON_ROTATABLE_TYPES.has(proto.type):
		return 0
	var x := _xprops(proto)
	var vt := VisualTurns.eligible(proto, x)
	if (proto.type == "assembling-machine" or proto.type == "furnace") and not vt and x.has("fo"):
		return 0
	if proto.type == "storage-tank":
		return 4 if posmod(build_dir, 8) == 4 else 0
	if proto.type != "straight-rail":
		return posmod(build_dir - build_dir % 4, 16)
	return build_dir


## Belts, loaders and the like lie under what drives or stands on them: Factorio's selection_priority
## for them is 45 (ground_entity), under a vehicle's 50, so a car over a belt is what the mouse picks.
const GROUND_ENTITY_TYPES := ["transport-belt", "underground-belt", "splitter", "lane-splitter", "loader", "loader-1x1", "linked-belt"]
const RAIL_TYPES := [
	"straight-rail", "half-diagonal-rail", "curved-rail-a", "curved-rail-b",
	"legacy-straight-rail", "legacy-curved-rail",
	"elevated-straight-rail", "elevated-half-diagonal-rail", "elevated-curved-rail-a", "elevated-curved-rail-b",
]


func _ground_entity(r: WorldMirror.Rec) -> bool:
	var proto: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
	return proto != null and GROUND_ENTITY_TYPES.has(proto.type)


func _is_rail_or_ground(r: WorldMirror.Rec) -> bool:
	if r == null or world == null or world.protos == null:
		return false
	var proto: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
	if proto == null:
		return false
	return GROUND_ENTITY_TYPES.has(proto.type) or RAIL_TYPES.has(proto.type) \
		or proto.type == "rail-ramp" or proto.type == "rail-support" \
		or proto.type == "resource" or proto.type == "tile-ghost" or proto.type == "entity-ghost" \
		or proto.type == "item-entity" or ModelLibrary.REMNANT_TYPES.has(proto.type)


## Builds/updates the reusable synthetic WorldMirror.Rec for `hovered_mover` (null when none hovered).
func _hovered_mover_record() -> WorldMirror.Rec:
	if hovered_mover.is_empty():
		_hovered_mover_rec = null
		return null
	var unit := int(hovered_mover[0])
	if _hovered_mover_rec == null or _hovered_mover_rec.unit != unit:
		_hovered_mover_rec = _mover_to_rec(hovered_mover)
	else:
		_hovered_mover_rec.proto_id = int(hovered_mover[1])
		_hovered_mover_rec.fixed = hovered_mover[2]
		_hovered_mover_rec.pos = hovered_mover[3]
		if hovered_mover.size() > 5:
			_hovered_mover_rec.dir = yaw_direction(float(hovered_mover[5]))
	return _hovered_mover_rec


static func _mover_to_rec(m: Array) -> WorldMirror.Rec:
	var r := WorldMirror.Rec.new()
	r.unit = int(m[0])
	r.key = "mover:%d" % r.unit
	r.proto_id = int(m[1])
	r.fixed = m[2]
	r.pos = m[3]
	r.dir = yaw_direction(float(m[5])) if m.size() > 5 else 0
	return r


## Currently hovered static entity or hovered mover (for EntityInfo and Shift+LMB paste).
func _selected_entity() -> WorldMirror.Rec:
	return hovered if hovered != null else _hovered_mover_record()


## World hover Y lift above terrain for `hovered_mover` (for CursorOverlay.brackets on elevated trains).
func hovered_mover_lift() -> float:
	return MoverLayer.hover_y(hovered_mover)


## Item #6: whether a plain LMB click while holding `held_proto` over `target` should open `target`
## instead of trying to build/drag-place.
func should_click_open_held(held_proto: ProtoDB.EntityProto, target: WorldMirror.Rec) -> bool:
	if held_proto == null or target == null or world == null or world.protos == null:
		return false
	var target_proto: ProtoDB.EntityProto = world.protos.entity(target.proto_id)
	if target_proto == null:
		return false
	# Real openable building only: ghosts (especially matching ghosts) must revive/build, not open.
	if target_proto.type == "entity-ghost" or target.extra.has("gh"):
		return false
	if not _openable(target):
		return false
	var held_x := _xprops(held_proto)
	var target_x := _xprops(target_proto)
	var held_fg := str(held_x.get("fg", ""))
	var target_fg := str(target_x.get("fg", ""))
	var same_group := held_fg != "" and held_fg == target_fg
	if not same_group and held_fg == "" and target_fg == "":
		var g1 := str(REPLACE_GROUPS.get(held_proto.type, ""))
		var g2 := str(REPLACE_GROUPS.get(target_proto.type, ""))
		same_group = (g1 != "" and g1 == g2) or (held_proto.type == target_proto.type and held_proto.id != target_proto.id and held_proto.tile_size == target_proto.tile_size)
	var target_q := str(target.extra.get("q", "normal"))
	if target_q == "":
		target_q = "normal"
	var diff_quality := cursor_quality != target_q
	# Fast-replace / upgrade (same fast_replaceable_group with different prototype or different quality).
	if same_group and held_proto.id != target_proto.id:
		return false
	if (same_group or held_proto.id == target_proto.id) and diff_quality:
		return false
	# Same rotatable entity at a different direction (e.g. clicking a belt/inserter to rotate it).
	if held_proto.id == target_proto.id:
		var rotatable := not NON_ROTATABLE_TYPES.has(held_proto.type) and not VisualTurns.eligible(held_proto, held_x)
		if (held_proto.type == "assembling-machine" or held_proto.type == "furnace") and held_x.has("fo"):
			rotatable = false
		if rotatable:
			var eff_dir := effective_build_dir(held_proto, false)
			var tgt_dir := (4 if posmod(target.dir, 8) == 4 else 0) if held_proto.type == "storage-tank" else target.dir
			if eff_dir != tgt_dir:
				return false
	return true


## Item #6: plain LMB with a placeable entity over a real openable building/mover opens it before
## `drag.begin` can run (disabled with --click-open-held=off).
func _try_click_open_held(mb: InputEventMouseButton) -> bool:
	if not click_open_held or mb.shift_pressed or mb.ctrl_pressed or mb.alt_pressed:
		return false
	if hud != null and hud.ui != null and hud.ui.remote:
		return false
	if cursor_tool != "" or cursor_item == "" or PLANNERS.has(cursor_item):
		return false
	if not tile_brush.use_of(cursor_item).is_empty() or not capsule_aim.use_of(cursor_item).is_empty() or not rail_planner.use_of(cursor_item).is_empty():
		return false
	if world == null or world.protos == null:
		return false
	var held_proto: ProtoDB.EntityProto = world.protos.placed_entity(cursor_item)
	if held_proto == null:
		return false
	if ROLLING_STOCK.has(held_proto.type) or RAIL_TYPES.has(held_proto.type) or held_proto.type == "rail-ramp" \
			or held_proto.type == "rail-support" or RailBlocks.is_rail_attachment(held_proto.type):
		return false
	if movers != null and rig != null and not over_gui and not _clean_shot:
		var r := rig.ray(_aim_screen())
		var m := _nearer_than_aim(movers.pick_ray(r[0], r[1], OPENABLE_MOVERS))
		if not m.is_empty():
			var at: Vector2i = m[2]
			_request_open(int(m[0]), {"t": "open", "u": int(m[0]), "p": int(m[1]), "x": at.x, "y": at.y})
			return true
	if not has_ground:
		return false
	var target: WorldMirror.Rec = _cursor_pick()
	if not should_click_open_held(held_proto, target):
		return false
	_open(target)
	return true


func _is_pole(r: WorldMirror.Rec) -> bool:
	var proto: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
	return proto != null and proto.type == "electric-pole"


## A click with a wire tool (or Shift+click on a pole: Factorio's "remove pole cables").
func _wire_click(shift: bool) -> void:
	var target: WorldMirror.Rec = hovered if hovered != null else (_cursor_pick() if has_ground else null)
	if shift and target != null and _is_pole(target) and cursor_tool in ["", "copper-wire"]:
		wire_tool.clear_cables(target)
		return
	var text := wire_tool.click(cursor_tool, target, ground)
	if text != "":
		hud.show_message(text)


## The vehicle or wagon the mouse ray hits (its oriented box and model), or [].
func _mover_under_mouse() -> Array:
	if movers == null or rig == null or over_gui or _clean_shot:
		return []
	var is_mod := cursor_tool == "" and hud != null and hud.ui != null and hud.ui.model != null and hud.ui.model.is_module(cursor_item)
	if cursor_item != "" and _cursor_is_buildable() and not is_mod:
		return []
	var screen := _aim_screen()
	var r := rig.ray(screen)
	return movers.pick_ray(r[0], r[1], HOVER_MOVERS)


## The vehicle or wagon under the mouse that the right button mines (anything held), or [].
func _mineable_mover_under_mouse() -> Array:
	if movers == null or over_gui or _clean_shot or (not has_ground and not mover_pick_3d):
		return []
	if not hovered_mover.is_empty() and MINEABLE_MOVERS.has(_mover_type(hovered_mover)):
		return hovered_mover
	if rig == null:
		return []
	var screen := _aim_screen()
	var r := rig.ray(screen)
	return _nearer_than_aim(movers.pick_ray(r[0], r[1], MINEABLE_MOVERS))


## The vehicle or wagon under the mouse a held repair pack mends (every one the right button mines), or [].
func _repairable_mover_under_mouse() -> Array:
	if movers == null or rig == null or over_gui or _clean_shot:
		return []
	var screen := _aim_screen()
	var r := rig.ray(screen)
	return _nearer_than_aim(movers.pick_ray(r[0], r[1], MINEABLE_MOVERS))


func _mover_type(m: Array) -> String:
	if world == null or world.protos == null:
		return ""
	var proto: ProtoDB.EntityProto = world.protos.entity(int(m[1]))
	return proto.type if proto != null else ""


## A click on a vehicle or wagon (a mover) opens its screen, like Factorio's.
func _open_mover() -> bool:
	var m: Array = hovered_mover
	if m.is_empty() or not OPENABLE_MOVERS.has(_mover_type(m)):
		return false
	var at: Vector2i = m[2]
	_request_open(int(m[0]), {"t": "open", "u": int(m[0]), "p": int(m[1]), "x": at.x, "y": at.y})
	return true


## The unit number of the nearest entity of this prototype the world mirror has, or 0.
func _nearest_named(proto_name: String) -> int:
	var best := 0
	var best_d := INF
	var here := Vector2(avatar.position.x, avatar.position.z) if avatar != null else Vector2.ZERO
	for key in world.entities:
		var r: WorldMirror.Rec = world.entities[key]
		if r.unit == 0 or world.protos.entity(r.proto_id) == null or world.protos.entity(r.proto_id).name != proto_name:
			continue
		var d := r.pos.distance_squared_to(here)
		if d < best_d:
			best_d = d
			best = r.unit
	return best


## Opens a building's screen. From the remote view it may be out of reach: the mod then opens it
## for its settings only, where radars cover it (`rv`), as Factorio 2.x does.
func _request_open(unit: int, cmd: Dictionary) -> void:
	if hud.ui.remote:
		cmd["rv"] = 1
		if hud.ui.viewing_si > 0:
			cmd["si"] = hud.ui.viewing_si
	hud.screen.request(unit, cmd)


func _open(r: WorldMirror.Rec) -> void:
	_request_open(r.unit, {"t": "open", "u": r.unit, "p": r.proto_id, "x": r.fixed.x, "y": r.fixed.y})


func _highlight_chunk_sig(pos: Vector2, radius_chunks: int) -> Array[int]:
	var c := WorldMirror.chunk_of(pos)
	var revs: Array[int] = [world.entity_count()]
	for dy in range(-radius_chunks, radius_chunks + 1):
		for dx in range(-radius_chunks, radius_chunks + 1):
			var cv = world.chunks.get(c + Vector2i(dx, dy))
			revs.append(int(cv.content_rev) if cv != null else -1)
	return revs


func _highlight_cache_key(placed: ProtoDB.EntityProto, ghost_mode: bool, ground_item: Array) -> Array:
	var hover_sig: Variant = null
	var hover_chunk_sig: Variant = null
	if hovered != null:
		var h_proto: ProtoDB.EntityProto = world.protos.entity(hovered.proto_id)
		var rn_sig: Variant = null
		if h_proto != null:
			if h_proto.type == "roboport":
				var info: Dictionary = hud.ui.model.hover_info
				if int(info.get("u", 0)) == hovered.unit:
					rn_sig = info.get("rn")
				hover_chunk_sig = world.entity_count()
			elif h_proto.type == "electric-pole":
				hover_chunk_sig = hud.ui.model.eprops.size()
		hover_sig = [hovered.key, hovered.unit, hovered.proto_id, hovered.pos, hovered.dir, hovered.extra.hash(), rn_sig, hover_chunk_sig]
	var mover_sig: Variant = null
	if not hovered_mover.is_empty():
		mover_sig = [hovered_mover[0], hovered_mover[3], hovered_mover[4], hovered_mover[5], hovered_mover_lift()]
	var gi_sig: Variant = [ground_item[0], ground_item[1]] if not ground_item.is_empty() else null
	var placed_sig: Variant = null
	if placed != null and has_ground:
		var at := build_point()
		var eff_dir := effective_build_dir(placed, ghost_mode)
		var size := placed.tile_size
		if eff_dir == 4 or eff_dir == 12:
			size = Vector2i(size.y, size.x)
		var pos := Vector2(_snap(at.x, size.x), _snap(at.y, size.y))
		if placed.type == "straight-rail":
			pos = Vector2(floorf(at.x / 2.0) * 2.0 + 1.0, floorf(at.y / 2.0) * 2.0 + 1.0)
		var on_rails := ROLLING_STOCK.has(placed.type)
		var is_rail_att := RailBlocks.is_rail_attachment(placed.type)
		var pos_key: Vector2 = Vector2(floorf(at.x * 4.0), floorf(at.y * 4.0)) if (on_rails or is_rail_att) else pos
		var in_reach := _in_reach(pos, size) if not on_rails else _in_reach(at, size)
		var rad := 2 if placed.type == "electric-pole" else 1
		var av_tile := Vector2i(floori(avatar.position.x), floori(avatar.position.z)) if (on_rails and avatar != null) else Vector2i.ZERO
		placed_sig = [
			placed.id, pos_key, eff_dir, build_mirror, ghost_mode,
			hud.ui.can_build_from_hand(), items_left(cursor_item) > 0, in_reach, av_tile,
			hud.ui.model.mines_with_fluid(), hud.ui.model.cant_build_reason(placed.id),
			_highlight_chunk_sig(pos, rad), _sent_unders().size(),
			rail_blocks.version if is_rail_att else 0,
		]
	return [
		hover_sig, mover_sig, gi_sig, placed_sig, has_ground,
		cursor_item, cursor_tool, cursor_quality,
		GroundHeight.version(), hud.ui.model.eprops.size(),
	]


func _update_highlights() -> void:
	var held := cursor_item if cursor_tool == "" else ""
	var placed: ProtoDB.EntityProto = world.protos.placed_entity(cursor_item) if cursor_item != "" and cursor_tool == "" else null
	if not rail_planner.anchor.is_empty() and not rail_planner.use_of(held).is_empty():
		placed = null  # the planner draws its path instead of one rail
	var ghost_mode := Input.is_key_pressed(KEY_SHIFT) or hud.count_of(cursor_item) == 0 or hud.ui.remote
	var ground_item: Array = []
	if has_ground and cursor_item == "" and cursor_tool == "" and hovered_mover.is_empty() and ground_items != null \
			and (hovered == null or _is_resource(hovered)) and ground_items.count() > 0:
		ground_item = ground_items.item_at(ground)
	var cache_eligible := hover_highlight_cache and not _lmb_down and _reverse_from == Vector2.INF \
		and cursor_tool != "spidertron" and cursor_tool != "paste" \
		and cursor_item != "blueprint" and cursor_item != "blueprint-book" \
		and tile_brush.use_of(held).is_empty() and capsule_aim.use_of(held).is_empty() \
		and rail_planner.use_of(held).is_empty() and rail_planner.anchor.is_empty()
	if cache_eligible:
		var key := _highlight_cache_key(placed, ghost_mode, ground_item)
		if _hl_cache_valid and key == _hl_cache_key:
			highlight_cache_hits += 1
			pipeline_vis.update(hovered, placed, hud.ui.alt_mode, ground if has_ground else null, hud.ui.model.eprops,
				hud.ui.model.hover_info, hud.ui.model.alerts)
			return
		_hl_cache_valid = true
		_hl_cache_key = key
	else:
		_hl_cache_valid = false
	highlight_rebuilds += 1
	_ghost.visible = false
	_ghost_model.visible = false
	for piece in _ghost_pieces:
		piece.visible = false
	_drag_box.visible = false
	_reach_lines.visible = false
	var marks: Array = []
	if hovered != null:
		var proto: ProtoDB.EntityProto = world.protos.entity(hovered.proto_id)
		if proto != null:
			var fc = hovered.extra.get("fc")
			var ghost_proto: ProtoDB.EntityProto = world.protos.entity(int(hovered.extra["gh"])) \
				if proto.type == "entity-ghost" and hovered.extra.has("gh") else null
			marks = hover_marks(proto, hovered.pos, hovered.dir, fc if fc is Array else [], ghost_proto)
			# J4: a pole hovered shows the area it supplies (one held shows every pole's, below).
			pole_cover.world = world
			var supplied := pole_cover.area_of(hovered, hud.ui.model.eprops)
			if supplied.has_area():
				marks.append(CursorOverlay.cover([supplied]))
			if proto.type == "roboport" and roboport_links != null:
				var info: Dictionary = hud.ui.model.hover_info
				var said = info.get("rn") if int(info.get("u", 0)) == hovered.unit else null
				for l in roboport_links.hovered_lines(hovered.pos, _logistic_radius(proto.id), hovered.unit, said):
					marks.append(CursorOverlay.line(l[0], l[1]))
	elif not hovered_mover.is_empty():
		marks.append(CursorOverlay.brackets(hovered_mover[3], hovered_mover[4], float(hovered_mover[5]), CursorOverlay.SELECTION, hovered_mover_lift()))
	# An item lying on the ground is selected over ore, as in Factorio (J18): its brackets instead.
	if not ground_item.is_empty():
		var half := Vector2(GroundItems.SELECT_HALF, GroundItems.SELECT_HALF)
		marks = [CursorOverlay.brackets(Vector2(ground_item[0]) / 256.0, half)]
	marks.append_array(_update_drag_box())
	if cursor_tool == "spidertron":
		spider_remote.query()
		marks.append_array(spider_remote.marks(movers))
	_update_paste_preview()
	tile_brush.update_preview(held, has_ground, ground, ghost_mode, _rmb_down)
	capsule_aim.update_preview(held, has_ground, ground)
	rail_planner.update(held, has_ground, ground, ghost_mode)
	_build_refusal = ""
	if placed != null and has_ground:
		var proto := placed
		var at := build_point()  # first person: beside the face looked at (K7)
		var dir := effective_build_dir(proto, ghost_mode)
		var size := proto.tile_size
		if dir == 4 or dir == 12:
			size = Vector2i(size.y, size.x)
		var pos := Vector2(_snap(at.x, size.x), _snap(at.y, size.y))
		if proto.type == "straight-rail":
			pos = Vector2(floorf(at.x / 2.0) * 2.0 + 1.0, floorf(at.y / 2.0) * 2.0 + 1.0)
		# Rolling stock goes on a rail (issue #12): drawn where the mod will put it, green on the
		# rails and red off them, never "blocked" by the rail it stands on.
		var on_rails := ROLLING_STOCK.has(proto.type)
		var is_rail_att := RailBlocks.is_rail_attachment(proto.type)
		var snap_el := 0
		var rail_snap_bad := false
		if on_rails:
			var spot := rolling_stock_spot(at, dir)
			if spot.is_empty():
				_build_refusal = "Rolling stock goes on rails"
				pos = at
			else:
				pos = spot[0]
				dir = spot[1]
		elif is_rail_att:
			var rb := rail_blocks.snap_and_marks(world, proto, at, dir, ghost_mode, hud.ui.model.eprops)
			marks.append_array(rb["marks"])
			pos = rb["pos"]
			dir = int(rb["dir"])
			snap_el = int(rb["el"])
			size = proto.tile_size
			if dir == 4 or dir == 12:
				size = Vector2i(size.y, size.x)
			if not bool(rb["valid"]):
				rail_snap_bad = true
				if _build_refusal == "":
					_build_refusal = str(rb["refusal"])
		# Space Age: the planet's pressure, gravity or magnetic field may forbid it (planet.nb).
		if _build_refusal == "":
			_build_refusal = hud.ui.model.cant_build_reason(proto.id)
		# Empty space (round a platform) holds nothing up: red, as Factorio draws it (F6).
		if _build_refusal == "" and snap_el == 0 and _on_void(pos, size):
			_build_refusal = "Can't build on empty space"
		# An offshore pump (anything with tile rules) shows the tiles it needs, green or red (I10).
		var rules := tile_rule_check(proto, pos, dir)
		marks.append_array(rules[1])
		if _build_refusal == "" and not bool(rules[0]):
			_build_refusal = "Needs water in front and land under it" if proto.type == "offshore-pump" else "Can't be built on these tiles"
		# L8: a drill needs a resource it mines under it (a pumpjack the oil well), as Factorio refuses it; the
		# resources it would mine are marked, and the wells Factorio highlights round the cursor.
		if _build_refusal == "":
			_build_refusal = ResourceHints.mining_refusal(world, hud.ui.model.eprops, proto, pos, hud.ui.model.mines_with_fluid())
		marks.append_array(ResourceHints.drill_marks(world, hud.ui.model.eprops, proto, pos))
		# L2: red, none left, once the builds sent have used up what the inventory shown still holds.
		var place_ok := (not rail_snap_bad) if is_rail_att else (on_rails or not _blocked(proto, pos, size, true))
		var ok := (ghost_mode or (hud.ui.can_build_from_hand() and _in_reach(pos, size) and items_left(cursor_item) > 0)) \
			and place_ok and _build_refusal == ""
		show_build_ghost(proto, pos, ok, ghost_mode, dir, snap_el)
		var x: Dictionary = hud.ui.model.eprops.get(proto.id, {}).get("x", {})
		marks.append_array(CursorOverlay.marks_for(proto.type, x, pos, dir, true))
		if UndergroundPairs.is_underground(proto.type):
			# J24: the connection to the piece it would join and the furthest it may go; red past that.
			# M2: a real build over a plain run of belts marks those it mines.
			marks.append_array(UndergroundPairs.held_marks(world, proto, pos, dir, _under_reach(proto), not ghost_mode, _sent_unders()))
		if proto.type == "roboport" and roboport_links != null:
			for l in roboport_links.held_lines(pos, _logistic_radius(proto.id)):
				marks.append(CursorOverlay.line(l[0], l[1]))
		if proto.type == "electric-pole":
			# J4: Factorio's electricity coverage, every pole's round the cursor and the held one's.
			pole_cover.world = world
			marks.append_array(pole_cover.held_marks(proto.id, cursor_quality, pos, hud.ui.model.eprops))
		_update_reach(proto, pos)
	_overlay.show_marks(marks)
	if placed != null and has_ground and not _ghost.visible and not _ghost_model.visible:
		_hl_cache_valid = false
	# N9: the hovered pipeline, and with a fluid entity held in Alt-mode every one round the cursor.
	pipeline_vis.update(hovered, placed, hud.ui.alt_mode, ground if has_ground else null, hud.ui.model.eprops,
		hud.ui.model.hover_info, hud.ui.model.alerts)


## A roboport prototype's logistic radius (tiles) from its `eprops` overlay.
func _logistic_radius(proto_id: int) -> float:
	return float(hud.ui.model.eprops.get(proto_id, {}).get("x", {}).get("lr", 25.0))


## The held item's entity where it would go: its model (or its picture card, a mod's building as the
## world draws it, or else a box) turned and flipped as it would be built, translucent, red when it
## can't be built there.
func show_build_ghost(proto: ProtoDB.EntityProto, pos: Vector2, ok: bool, ghost_mode: bool, dir := -1, el := 0) -> void:
	if dir < 0:
		dir = build_dir
	var extra := build_extra(proto, pos, dir, el)
	# The model is read on a worker thread the first time (mesh_for alone parsed its .glb here, in
	# the frame the item was first held): nothing shows for the few frames until it is made.
	if not ModelLibrary.entity_ready(proto.name, proto.type, extra, dir):
		return
	var flip := Basis.from_scale(Vector3(-1, 1, 1)) if build_mirror else Basis.IDENTITY
	var b_ends := Ghosts.lone_belt_ends(proto.type, extra)
	var cb := world.cargo_mask(WorldMirror.cargo_rect(proto, pos), true) if proto.type == "cargo-bay" else -1
	var fb: Variant = world._fluid_ports.get(proto.id) if world != null else null
	var pieces := Ghosts.ghost_pieces(proto.name, proto.type, extra, dir, pos, b_ends, flip, cb, fb)
	if not pieces.is_empty():
		var mat: Material = _ghost_model_materials[("ghost" if ghost_mode else "ok") if ok else "bad"]
		_ghost_model.mesh = pieces[0][0]
		_ghost_model.transform = pieces[0][1]
		_ghost_model.material_override = mat
		_ghost_model.visible = true
		for pi in range(1, pieces.size()):
			var piece := _ghost_piece(pi - 1)
			piece.mesh = pieces[pi][0]
			piece.transform = pieces[pi][1]
			piece.set_meta("model", "")
			piece.material_override = mat
			piece.visible = piece.mesh != null
		return
	var lift := Visuals.flight_lift(proto.type)
	var card := SpriteStandins.card(proto.name, dir, proto.size(), proto.type) if proto.type != "resource" else null
	if card != null:
		# The card faces Factorio's camera whatever the direction (the direction picks the picture).
		_ghost_model.mesh = card
		_ghost_model.transform = SpriteStandins.transform(pos, lift)
		_ghost_model.material_override = SpriteStandins.ghost_material(card, _ghost_model_tints[("ghost" if ghost_mode else "ok") if ok else "bad"])
		_ghost_model.visible = true
		return
	_ghost.transform = Visuals.placeholder_transform(proto, pos, dir, Visuals.height_for(proto), lift)
	_ghost.transform.basis = _ghost.transform.basis * flip
	_ghost.material_override = (_ghost_blue if ghost_mode else _ghost_ok) if ok else _ghost_bad
	_ghost.visible = true


func _ghost_piece(i: int) -> MeshInstance3D:
	while i >= _ghost_pieces.size():
		var mi := MeshInstance3D.new()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		world.add_child(mi)
		_ghost_pieces.append(mi)
	return _ghost_pieces[i]


## What hovering over an entity shows, like Factorio: its selection box's corners, and from its
## `eprops` overlay an inserter's pickup and drop arrows, a roboport's logistic and construction
## areas, a mining drill's area and output, fluid connections.
func hover_marks(proto: ProtoDB.EntityProto, pos: Vector2, dir: int, fc: Array = [], ghost_proto: ProtoDB.EntityProto = null) -> Array:
	var target_proto: ProtoDB.EntityProto = ghost_proto if ghost_proto != null else proto
	var rect := WorldMirror.selection_rect(target_proto, pos, dir)
	var marks: Array = [CursorOverlay.brackets(rect.get_center(), rect.size * 0.5)]
	var x: Dictionary = hud.ui.model.eprops.get(target_proto.id, {}).get("x", {})
	marks.append_array(CursorOverlay.marks_for(target_proto.type, x, pos, dir, false, fc))
	return marks


## The extra data the held item's model is picked by (ModelLibrary.model_name), as the entity would
## have it there: a straight belt, an underground's end (an exit when the nearest underground of its
## kind behind it facing the same way, or its ghost, is an entrance: the mod builds it so), a pipe joined
## to what it would join there (L8, resource_hints.gd), a lone wall piece.
func build_extra(proto: ProtoDB.EntityProto, pos: Vector2, dir: int, el := 0) -> Dictionary:
	match proto.type:
		"transport-belt":
			return {"s": "s"}
		"pipe", "heat-pipe":
			var tile := Vector2i(floori(pos.x), floori(pos.y))
			return {"pc": ResourceHints.held_pipe_mask(world, hud.ui.model.eprops if hud != null else {}, tile, proto.type == "heat-pipe")}
		"wall":
			return {"wc": 0}
		"underground-belt":
			var join := UndergroundPairs.held_join(world, proto, pos, dir, _under_reach(proto), _sent_unders())
			return {"u": "o" if not join.is_empty() and not bool(join["far"]) else "i"}
		"mining-drill":
			if hud == null or hud.ui == null or hud.ui.model == null or world == null:
				return {}
			var eprops: Dictionary = hud.ui.model.eprops
			var x: Dictionary = (eprops.get(proto.id, {}) as Dictionary).get("x", {})
			if not ResourceHints._takes_fluid(x):
				return {}
			var cats := ResourceHints._categories(x)
			var r := float(x.get("mr", 0.0))
			for pair in ResourceHints.resources_in(world, pos, r, eprops):
				var rx: Dictionary = (eprops.get((pair[1] as ProtoDB.EntityProto).id, {}) as Dictionary).get("x", {})
				var cat := str(rx.get("rk", ""))
				if (cats.is_empty() or cat == "" or cats.has(cat)) and rx.has("rf"):
					return {"fa": 1}
			return {}
		"rail-signal", "rail-chain-signal":
			return {"el": 1} if el == 1 else {}
	return {}


## The undergrounds just sent to be built that the world doesn't have yet (predicted.gd, M2): the
## cursor pairs with them as the build will.
func _sent_unders() -> Array:
	return predicted.sent_undergrounds() if predicted != null else []


## An underground belt's or pipe-to-ground's reach from the mod's `eprops` (its max_distance), or 0.
func _under_reach(proto: ProtoDB.EntityProto) -> int:
	return int(hud.ui.model.eprops.get(proto.id, {}).get("under", 0.0)) if proto != null else 0


## Factorio's build previews: an electric pole's wires to the poles in reach (its supply area, with
## the poles' round it, is the overlay's: pole_coverage.gd; an underground's reach too, J24). From the
## mod's `eprops`.
func _update_reach(proto: ProtoDB.EntityProto, pos: Vector2) -> void:
	var props: Dictionary = hud.ui.model.eprops.get(proto.id, {})
	if props.is_empty():
		return
	var wire := float(props.get("wire", 0.0))
	_reach_mesh.clear_surfaces()
	var lines := 0
	if wire > 0.0:
		_reach_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
		var center := WorldMirror.chunk_of(pos)
		# A wire needs both poles' reach: the shorter of the two (a big pole next to a small one
		# connects at the small one's), and a new pole takes the nearest five.
		var near: Array = []
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var cv = world.chunks.get(center + Vector2i(dx, dy))
				if cv == null:
					continue
				for r in cv.entities.values():
					var other: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
					if other == null or other.type != "electric-pole":
						continue
					var reach := minf(wire, float(hud.ui.model.eprops.get(r.proto_id, {}).get("wire", wire)))
					var dist: float = r.pos.distance_to(pos)
					if dist <= reach:
						near.append([dist, r.pos])
		near.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
		for n in near.slice(0, 5):
			_reach_mesh.surface_add_vertex(Vector3(pos.x, 2.0, pos.y))
			_reach_mesh.surface_add_vertex(Vector3(n[1].x, 2.0, n[1].y))
			lines += 1
		if lines == 0:  # an empty surface isn't allowed
			_reach_mesh.surface_add_vertex(Vector3(pos.x, 2.0, pos.y))
			_reach_mesh.surface_add_vertex(Vector3(pos.x, 2.0, pos.y))
		_reach_mesh.surface_end()
		_reach_lines.visible = true


## The box being dragged with a planner or tool, in its colour, and Factorio's highlight round
## each entity it will take (marks for the overlay).
func _update_drag_box() -> Array:
	var reverse := _reverse_from != Vector2.INF and (cursor_item == "upgrade-planner" or cursor_tool == "spidertron")
	if not (_lmb_down or reverse) or not has_ground:
		return []
	var kind := cursor_tool
	if kind == "":
		kind = {"deconstruction-planner": "decon", "upgrade-planner": "upgrade"}.get(cursor_item, "")
	if kind == "" or kind == "paste":
		return []
	var shift := Input.is_key_pressed(KEY_SHIFT) and not reverse
	var cancel := shift and kind in ["decon", "upgrade"]
	var r := Rect2(_reverse_from if reverse else _drag_from, Vector2.ZERO).expand(ground)
	var color := selection_color(kind, shift, reverse) if kind != "spidertron" else SpiderRemote.box_color(shift, reverse)
	var material := GroundHeight.mark_material(Color(color, 0.95), false)
	var t := BOX_EDGE
	var c := r.get_center()
	# top, bottom, left, right
	var edges := [[Vector2(c.x, r.position.y), Vector2(r.size.x + t, t)], [Vector2(c.x, r.end.y), Vector2(r.size.x + t, t)],
		[Vector2(r.position.x, c.y), Vector2(t, r.size.y + t)], [Vector2(r.end.x, c.y), Vector2(t, r.size.y + t)]]
	_drag_box.transform = Transform3D.IDENTITY
	for i in 4:
		var edge := _drag_box.get_child(i) as MeshInstance3D
		var at: Vector2 = edges[i][0]
		var sz: Vector2 = edges[i][1]
		edge.transform = Transform3D(Basis.from_scale(Vector3(sz.x, 0.04, sz.y)), Vector3(at.x, 0.05, at.y))
		edge.material_override = material
	_drag_box.visible = true
	var marks: Array = []
	if kind == "spidertron":
		for u in SpiderRemote.spiders_in(movers, r):
			var at = movers.position_of(u)
			if at is Vector3:
				marks.append(CursorOverlay.brackets(Vector2(at.x, at.z), Vector2(1.5, 1.5), 0.0, color))
		return marks
	for e in (selected_by(kind, r, cancel) if not reverse else downgraded_by(r)):
		var proto: ProtoDB.EntityProto = world.protos.entity(e.proto_id)
		var box := WorldMirror.selection_rect(proto, e.pos, e.dir)
		marks.append(CursorOverlay.brackets(box.get_center(), box.size * 0.5, 0.0, color))
		if marks.size() >= 400:
			break
	return marks


## The selection box: four thin edges under one node (the node itself draws nothing).
func _box_edges() -> void:
	_drag_box.mesh = null
	while _drag_box.get_child_count() < 4:
		var edge := MeshInstance3D.new()
		edge.mesh = Visuals.box_mesh()
		edge.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_drag_box.add_child(edge)


## Factorio's selection colour of a tool: select, alt_select (Shift) or reverse_select (right-drag).
static func selection_color(kind: String, shift: bool, reverse := false) -> Color:
	if reverse and kind == "upgrade":
		return SELECT_COLORS["upgrade_reverse"]
	return SELECT_COLORS.get(kind + ("_alt" if shift else ""), SELECT_COLORS["blueprint"])


## What an upgrade planner's right-drag takes: what its mappings lead to (downgraded back).
func downgraded_by(r: Rect2) -> Array:
	var settings = BpString.body(hud.ui.planners.held_record).get("settings", {}) if not hud.ui.planners.held_record.is_empty() else {}
	var targets := {}
	if settings is Dictionary:
		for m in BpString._list(settings.get("mappers")):
			if m.get("to") is Dictionary and m.get("from") is Dictionary:
				targets[str(m["to"].get("name", ""))] = true
	var out: Array = []
	var c0 := WorldMirror.chunk_of(r.position)
	var c1 := WorldMirror.chunk_of(r.end)
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var cv = world.chunks.get(Vector2i(cx, cy))
			if cv == null:
				continue
			for e in cv.entities.values():
				var proto: ProtoDB.EntityProto = world.protos.entity(e.proto_id)
				if proto != null and r.has_point(e.pos) and targets.has(proto.name):
					out.append(e)
	return out


## Whether a selection area takes an entity with this selection box: the two overlap, or the area is
## a point (a click) inside the box.
static func selection_touches(box: Rect2, area: Rect2) -> bool:
	return box.intersects(area.grow(0.01))


## The entities a selection of this kind over the rect takes, as Factorio picks them: the
## deconstruction planner by its filters (whitelist / blacklist, trees and rocks only), the
## upgrade planner what it has a mapping for, blueprints and copies the force's buildings (not
## trees, rocks or ore); with `cancel`, what carries that mark.
func selected_by(kind: String, r: Rect2, cancel: bool) -> Array:
	var out: Array = []
	var planner: Dictionary = hud.ui.planners.held_record if cursor_tool == "" else {}
	var settings = BpString.body(planner).get("settings", {}) if not planner.is_empty() else {}
	if not (settings is Dictionary):
		settings = {}
	var filters := {}
	for f in BpString._list(settings.get("entity_filters")):
		filters[str(f.get("name", ""))] = true
	var blacklist := int(settings.get("entity_filter_mode", 0)) == 1
	var nature_only := bool(settings.get("trees_and_rocks_only", false))
	var upgrades := {}
	for m in BpString._list(settings.get("mappers")):
		if m.get("from") is Dictionary:
			upgrades[str(m["from"].get("name", ""))] = true
	# The game takes what the area touches (the selection box overlapping it), not only what has its
	# middle inside; a bare click is a point. Entities sit in the chunk of their middle, so look a
	# big machine's reach further.
	var reach := r.grow(8.0)
	var c0 := WorldMirror.chunk_of(reach.position)
	var c1 := WorldMirror.chunk_of(reach.end)
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var cv = world.chunks.get(Vector2i(cx, cy))
			if cv == null:
				continue
			for e in cv.entities.values():
				var proto: ProtoDB.EntityProto = world.protos.entity(e.proto_id)
				if proto == null or proto.type == "resource" or proto.type == "character":
					continue
				if not selection_touches(WorldMirror.selection_rect(proto, e.pos, e.dir), r):
					continue
				var nature := NATURE_TYPES.has(proto.type)
				var ok := false
				match kind:
					"decon":
						if cancel:
							ok = e.extra.has("d")
						elif nature_only:
							ok = nature
						elif filters.is_empty():
							ok = true
						else:
							ok = filters.has(proto.name) != blacklist
					"upgrade":
						ok = e.extra.has("up") if cancel else (upgrades.is_empty() or upgrades.has(proto.name)) and not nature and proto.type != "entity-ghost"
					_:
						ok = not nature and e.unit > 0
				if ok:
					out.append(e)
	return out


## While pasting, or holding a blueprint: its entities as their models in Factorio's ghost blue
## round the mouse, red where they can't go, turned with R and flipped with H / V
## (blueprint_preview.gd, K11).
func _update_paste_preview() -> void:
	var held := has_ground and cursor_tool == "" and cursor_item in ["blueprint", "blueprint-book"]
	if not has_ground or not (held or cursor_tool == "paste"):
		bp_preview.clear()
		return
	var turn := build_dir / 4
	var mode := 2 if Input.is_key_pressed(KEY_SHIFT) and Input.is_key_pressed(KEY_CTRL) else (1 if Input.is_key_pressed(KEY_SHIFT) else 0)
	if held:
		var entries: Array = hud.ui.planners.held_preview(world.protos)
		bp_preview.show_blueprint(["bp", hud.ui.planners.preview_version], entries, hud.ui.planners.held_preview_tiles(),
			blueprint_preview_centre(ground), turn, build_mirror, mode)
		return
	var clip: Array = hud.ui.model.clipboard
	if clip.is_empty():
		bp_preview.clear()
		return
	# The mod pastes the clipboard forced (ui_actions.lua M.paste): trees and rocks are marked.
	bp_preview.show_blueprint(["clip", _clip_version], clip, [], _paste_centre(clip[0], turn), turn, false, maxi(mode, 1))


## Where the clipboard's middle goes (its offsets are from the middle of its footprints): the mouse,
## moved as little as puts its first entity on the tile grid, as Factorio pastes it.
func _paste_centre(first: Dictionary, turn: int) -> Vector2:
	return _paste_centre_at(ground, first, turn)


func _paste_centre_at(at: Vector2, first: Dictionary, turn: int) -> Vector2:
	var proto: ProtoDB.EntityProto = world.protos.entity(int(first["p"]))
	if proto == null:
		return Vector2(roundf(at.x), roundf(at.y))
	var offset: Vector2 = first["at"]
	for t in turn:
		offset = Vector2(-offset.y, offset.x)
	var size := proto.tile_size
	if posmod(int(first["d"]) + turn * 4, 8) == 4:
		size = Vector2i(size.y, size.x)
	var on := at + offset
	return Vector2(_snap(on.x, size.x), _snap(on.y, size.y)) - offset  # exact: half tiles less half tiles


## L2: how many of `item` the hand can still build with: the inventory shown less the builds sent
## that it hasn't lost yet (predicted.gd spend; the inventory alone with `--build-spend=off`).
func items_left(item: String) -> int:
	var unpaid := predicted.unpaid(item) if predicted != null else 0
	return maxi(0, hud.count_of(item) - unpaid)


## Within the character's build distance (to the footprint's nearest edge, as Factorio measures).
func _in_reach(pos: Vector2, size: Vector2i) -> bool:
	if avatar == null:
		return true
	var c := avatar.ground_position()
	var half := Vector2(size) * 0.5
	var d := Vector2(maxf(0.0, absf(c.x - pos.x) - half.x), maxf(0.0, absf(c.y - pos.y) - half.y))
	return d.length() <= build_reach()


## What the bridge adds to the build distance, measuring to a building's middle (building.lua REACH_SLACK).
const BRIDGE_REACH_SLACK := 1.5


## Within the bridge's own reach for a build: the character's build distance plus its slack, to the
## building's middle. A little past _in_reach for a small building (the preview is red there and the
## bridge still builds), short of it for a big one; what the game will take is counted by this (L2).
func _bridge_reach(pos: Vector2) -> bool:
	if avatar == null:
		return true
	return avatar.ground_position().distance_to(pos) <= build_reach() + BRIDGE_REACH_SLACK


## The character's build distance now (other mods and research may add to it), from `cinfo`.
func build_reach() -> float:
	if hud != null and hud.ui != null and hud.ui.model != null:
		return hud.ui.model.build_reach()
	return BUILD_REACH


## Types that fast-replace each other across types, by their fast_replaceable_group in 2.1's base
## data: belts, undergrounds and splitters ("transport-belt"); pipes and pipes-to-ground ("pipe"); chests and
## logistic chests ("container"); walls and gates ("wall").
const REPLACE_GROUPS := {"transport-belt": "belt", "underground-belt": "belt", "splitter": "belt",
	"pipe": "pipe", "pipe-to-ground": "pipe", "container": "container", "logistic-container": "container",
	"wall": "wall", "gate": "wall"}


## `eprops`' `x` overlay of a prototype (fg, cb, wb: what the game's own placement rules read), {} when unknown.
func _xprops(proto: ProtoDB.EntityProto) -> Dictionary:
	if hud == null or hud.ui == null or hud.ui.model == null:
		return {}
	var e = hud.ui.model.eprops.get(proto.id)
	return e.get("x", {}) if e is Dictionary else {}


## A collision box (`cb`: four numbers from the centre facing north) of a prototype, or its selection box.
func _solid_rect(proto: ProtoDB.EntityProto, pos: Vector2, dir: int) -> Rect2:
	var cb = _xprops(proto).get("cb")
	if cb is Array and cb.size() == 4:
		return WorldMirror.box_rect(Vector2(float(cb[0]), float(cb[1])), Vector2(float(cb[2]), float(cb[3])), pos, dir)
	return WorldMirror.selection_rect(proto, pos, dir)


## Something other than ore, ghosts or what the item can replace (the same entity: it turns; the
## same fast-replace group and size: a fast-replace, like a faster belt) is in the footprint. Movers aren't checked. With
## `replacing` (the build cursor's colour), what it replaces across types doesn't count either: a
## splitter or an underground over belts, a pipe-to-ground over pipes, as Factorio shows them (J9).
## What is in the way is its collision box, not its selection box: a tree's crown, or a belt's tile, is
## not solid (a chest stands a tile from a tree Factorio shows red under), and water stops an entity whose
## collision mask holds it (a chest on a lake).
func _blocked(proto: ProtoDB.EntityProto, pos: Vector2, size: Vector2i, replacing := false) -> bool:
	var held_x := _xprops(proto)
	var area := Rect2(pos - Vector2(size) * 0.5, Vector2(size)).grow(-0.05)
	var cb = held_x.get("cb")
	if cb is Array and cb.size() == 4:
		var half := Vector2(float(cb[2]) - float(cb[0]), float(cb[3]) - float(cb[1])) * 0.5
		if (size.x != proto.tile_size.x or size.y != proto.tile_size.y) and size.x == proto.tile_size.y:
			half = Vector2(half.y, half.x)
		area = Rect2(pos - half, half * 2.0).grow(-0.01)
	if area.size.x <= 0.0 or area.size.y <= 0.0:
		return false
	if held_x.has("wb") and not held_x.has("tb") and _on_water(area):
		return true
	var fg := str(held_x.get("fg", ""))
	var group := str(REPLACE_GROUPS.get(proto.type, "")) if replacing and fg == "" else ""
	for r: WorldMirror.Rec in world.entities_overlapping(area):
		var other: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
		if other == null or other.type in ["resource", "entity-ghost", "tile-ghost"]:
			continue
		if fg != "":
			# The game's own rule (fast_replaceable_group): the same group, and the same size where it
			# stands (a belt group's pieces, a splitter over two belts, any size).
			if str(_xprops(other).get("fg", "")) == fg:
				if fg == "transport-belt" and replacing:
					continue
				if other.tile_size == proto.tile_size and r.pos.distance_to(pos) < 0.75:
					continue
				if other.tile_size.x == proto.tile_size.y and other.tile_size.y == proto.tile_size.x and r.pos.distance_to(pos) < 0.75:
					continue
		else:
			# The same type: a fast-replace (or the same thing turning) where it stands on the same spot;
			# overlapping one a tile along (an assembler over an assembler) is in the way, as in Factorio.
			if other.type == proto.type and (r.pos.distance_to(pos) < 0.75 or proto.type.contains("rail")):
				continue
			if group != "" and REPLACE_GROUPS.get(other.type, "") == group:
				continue
		if proto.type.contains("rail") and other.type == proto.type:
			continue
		var other_rect := _solid_rect(other, r.pos, r.dir)
		if other_rect.size.x > 0.0 and other_rect.size.y > 0.0 and other_rect.intersects(area):
			return true
	return false


## Whether a tile under `area` (its footprint's collision box) is water.
func _on_water(area: Rect2) -> bool:
	for y in range(floori(area.position.y), floori(area.end.y - 0.0001) + 1):
		for x in range(floori(area.position.x), floori(area.end.x - 0.0001) + 1):
			var id: int = world.tile_at(x, y)
			if id >= 0 and world.protos.is_water(id):
				return true
	return false


## Where held rolling stock goes, as the mod builds it (building.lua, on_rail): on the nearest
## straight rail within RAIL_SEARCH tiles of `at`, facing along it (`dir` picks which way along).
## [position, direction], or [] with no rail there.
func rolling_stock_spot(at: Vector2, dir: int) -> Array:
	var best: WorldMirror.Rec = null
	var best_d := RAIL_SEARCH
	var center := WorldMirror.chunk_of(at)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var cv = world.chunks.get(center + Vector2i(dx, dy))
			if cv == null:
				continue
			for r in cv.entities.values():
				if absf(r.pos.x - at.x) > RAIL_SEARCH or absf(r.pos.y - at.y) > RAIL_SEARCH:
					continue
				var other: ProtoDB.EntityProto = world.protos.entity(r.proto_id)
				if other == null or not STOCK_RAILS.has(other.type):
					continue
				var d: float = r.pos.distance_to(at)
				if d <= best_d:
					best = r
					best_d = d
	if best == null:
		return []
	var axis := best.dir % 8
	return [best.pos, dir if axis == dir % 8 else axis]


## Whether a tile under the footprint is empty space (nothing to stand on, as round a platform).
func _on_void(pos: Vector2, size: Vector2i) -> bool:
	var x0 := floori(pos.x - size.x * 0.5 + 0.05)
	var y0 := floori(pos.y - size.y * 0.5 + 0.05)
	for dy in size.y:
		for dx in size.x:
			if world.protos.is_void(world.tile_at(x0 + dx, y0 + dy)):
				return true
	return false


## 2.1's offshore pump (data/base/prototypes/entity/entities.lua), for a bridge that sends no `tb`.
const OFFSHORE_TILE_RULES := [[-0.4, -0.4, 0.4, 0.4, "g", "w"], [-1.0, -2.0, 1.0, -1.0, "w", ""]]
const TILE_OK := Color(0.25, 0.9, 0.35)
const TILE_BAD := Color(1.0, 0.25, 0.2)


## The tile rules of a prototype (`eprops` x.tb, I10): [whether every rule holds at `pos` facing
## `dir`, the marks: each tile a rule covers, green where it holds and red where not]. Tiles not
## loaded yet count as holding. [true, []] without rules.
func tile_rule_check(proto: ProtoDB.EntityProto, pos: Vector2, dir: int) -> Array:
	var rules: Array = hud.ui.model.eprops.get(proto.id, {}).get("x", {}).get("tb", [])
	if rules.is_empty() and proto.type == "offshore-pump":
		rules = OFFSHORE_TILE_RULES
	var marks: Array = []
	var all_ok := true
	for r in rules:
		if not (r is Array and r.size() >= 6):
			continue
		var a := CursorOverlay.turn(Vector2(float(r[0]), float(r[1])), dir)
		var b := CursorOverlay.turn(Vector2(float(r[2]), float(r[3])), dir)
		var lo := pos + Vector2(minf(a.x, b.x), minf(a.y, b.y))
		var hi := pos + Vector2(maxf(a.x, b.x), maxf(a.y, b.y))
		# The tiles the area overlaps (an edge only touching a tile doesn't count).
		for ty in range(floori(lo.y + 0.01), floori(hi.y - 0.01) + 1):
			for tx in range(floori(lo.x + 0.01), floori(hi.x - 0.01) + 1):
				var id := world.tile_at(tx, ty)
				var good: bool = id < 0 or ((str(r[4]) == "" or _tile_is(id, str(r[4])))
					and (str(r[5]) == "" or not _tile_is(id, str(r[5]))))
				all_ok = all_ok and good
				var c := TILE_OK if good else TILE_BAD
				marks.append(CursorOverlay.area(Rect2(Vector2(tx, ty) + Vector2(0.08, 0.08), Vector2(0.84, 0.84)),
					Color(c, 0.28), Color(c, 0.9)))
	return [all_ok, marks]


## Whether tile `id` is of a kind a tile rule names: "w" water, "g" ground (neither water nor
## empty space).
func _tile_is(id: int, kind: String) -> bool:
	if kind == "w":
		return world.protos.is_water(id)
	return not world.protos.is_water(id) and not world.protos.is_void(id)


## Same grid snapping as the mod: odd sizes centre on a tile, even sizes on a tile corner (rails:
## a two-tile grid, see _update_highlights). Factorio's own rule (its prototype docs' tile_width: odd,
## the centre in the middle of a tile; even, on the tile transition; create_entity in real 2.1.24
## snaps a splitter the same in every direction, J9).
static func _snap(v: float, size: int) -> float:
	if size % 2 == 1:
		return floorf(v) + 0.5
	return floorf(v + 0.5)


## J9 (the owner: placing a splitter over a belt sometimes shifts it over one tile): a cursor point
## on the wire, in 1/256 tile, for what the mod snaps to the grid (`build`, `tile`, `tile_mine`).
## Rounded down, so the mod's snap of it is the preview's snap of the point itself for every point
## (floor(floor(256 v) / 256 + c) == floor(v + c) for c 0 or 0.5). int() cut towards zero, which at
## negative coordinates is up: a point less than 1/256 tile under a tile's edge (an odd size) or its
## middle (an even one, a splitter aimed at a belt's middle) was sent as the edge itself, and the
## mod built one tile over from the preview. `--build-wire=truncate`: as before.
static var wire_floor := not (Switches.has("--build-wire=truncate"))


static func wire(v: float) -> int:
	return floori(v * 256.0) if wire_floor else int(v * 256.0)


## Puts an item in the cursor (the quickbar, a picked-up stack), or empties it with "". Anything
## can be held, as in Factorio; only what places an entity (or a planner) builds.
func hold(item: String, slot := 0) -> void:
	reselect_slot = 0
	if item != cursor_item:
		cursor_quality = "normal"
		rail_planner.clear()
		tile_brush.alt = false
	cursor_item = item
	cursor_tool = ""
	cursor_slot = slot if item != "" else 0
	wire_tool.cancel()
	if item == "":
		build_mirror = false
	if PLANNERS.has(item):
		hud.ui.planners.held_changed(item, planner_slot())


## Puts one of the shortcut tools (TOOLS) in the cursor.
func hold_tool(tool: String) -> void:
	hold(str(TOOLS.get(tool, "")))
	cursor_tool = tool
