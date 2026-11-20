extends Node3D
## Factorio's Alt-mode arrows (issue #9 part 2), as its Interface settings choose them: "Show
## inserter arrows in Alt-mode" (off by default) puts its yellow indication arrow where each
## inserter picks up and where it drops; "Show pump arrows" its blue fluid arrow where a pump's
## fluid leaves; "Show machine arrows" one at every fluid connection a machine uses, pointing in or
## out (both ways: Factorio's two-headed one), and the yellow arrow on the side a recycler drops its
## results. With Factorio's own sprites (core/graphics/arrows), flat over the ground and over
## everything, as its overlays are.
##
## A crafting machine shows only the connections its recipe uses (the record's `extra.fa`: 1 fluid
## in, 2 fluid out; boilers and pumps all theirs); where they are comes from the prototype's
## `eprops` (fb, ip / id, vp). Arrows are worked out per chunk when its records change and kept;
## each of the three sprites is one MultiMesh filled from the chunks in the camera's view, again
## only when that set or a chunk changes. Not in the 3D remote view's fog (remote_fog.gd).
##
## A crafting machine whose record has `fc` (L10: its connections and the fluid each takes or gives, as the
## bridge reads them) gets its arrows from those and the fluid's icon at each, as Factorio's Alt-mode draws it
## (PipeConnectionDefinition::hide_connection_info: "connection arrows and fluid icons"), one MultiMesh a
## fluid; --fluid-icons=off as before.

const WorldMirror := preload("res://scripts/world/world.gd")
const GuiAssets := preload("res://scripts/ui/factorio/gui_assets.gd")
const AltOverlay := preload("res://scripts/ui/factorio/alt_overlay.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
const CursorOverlay := preload("res://scripts/player/cursor_overlay.gd")
const Kit := preload("res://scripts/ui/factorio/kit.gd")

## [sprite under core/graphics, size in tiles] for the three kinds: Factorio's utility sprites
## indication_arrow (64 px at scale 0.5) and fluid_indication_arrow(_both_ways) (48 px at 0.5).
const SPRITES := [["arrows/indication-arrow.png", 1.0], ["arrows/fluid-indication-arrow.png", 0.75],
	["arrows/fluid-indication-arrow-both-ways.png", 0.75]]
const INDICATION := 0
const FLUID := 1
const FLUID_BOTH := 2
## A fluid's icon at a connection (arrows_for's fourth kind; its fourth value the fluid).
const ICON := 3
const LIFT := 0.08
## Crafting machines: their connections show only while the recipe uses fluid that way.
const CRAFTERS := ["assembling-machine", "furnace"]
## What else "machine arrows" covers, every connection of theirs (as in 2.1.23 with a fresh config).
const MACHINES := ["boiler", "generator", "fusion-reactor", "fusion-generator"]
const PUMPS := ["pump", "offshore-pump"]

var world: WorldMirror
var model  # ui_model.gd: eprops
var fog: Node = null  # remote_fog.gd
var alt_mode := false

var _layers: Array[MultiMeshInstance3D] = []
## Fluid icons by fluid (L10), made as a fluid is first drawn.
var _icon_layers := {}
var _chunk_arrows := {}  # chunk -> [[Transform3D], [Transform3D], [Transform3D], {fluid: [Transform3D]}] by kind
var _dirty := {}  # chunk -> true
var _all_dirty := true
var _shown_key := ""  # the chunks in view (and the fog's state) the MultiMeshes were filled for
var _settings_key := ""
var _settings_timer := 0.0
## Arrows drawn (tests).
var drawn := 0
## Fluid icons drawn (tests).
var icons_drawn := 0


func _ready() -> void:
	for kind in SPRITES.size():
		# Factorio's sprite over everything, on the hills (ground_height.gd).
		var mat := GroundHeight.overlay_material(10, GuiAssets.core_sprite(str(SPRITES[kind][0])))
		var quad := QuadMesh.new()
		quad.orientation = PlaneMesh.FACE_Y
		quad.size = Vector2.ONE * float(SPRITES[kind][1])
		quad.material = mat
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = quad
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visible = false
		add_child(mmi)
		_layers.append(mmi)
	if world != null:
		world.entities_changed.connect(func(c: Vector2i) -> void: _dirty[c] = true)
		world.alt_changed.connect(func(c: Vector2i) -> void: _dirty[c] = true)


func _process(delta: float) -> void:
	_settings_timer -= delta
	if _settings_timer <= 0.0:
		_settings_timer = 0.5
		var key := "%s%s%s" % [Settings.get_value("interface", "alt_inserter_arrows"),
			Settings.get_value("interface", "alt_pump_arrows"), Settings.get_value("interface", "alt_machine_arrows")]
		if key != _settings_key:
			_settings_key = key
			_all_dirty = true
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if not alt_mode or world == null or model == null or camera == null:
		for l in _layers:
			l.visible = false
		for l in _icon_layers.values():
			(l as MultiMeshInstance3D).visible = false
		return
	refresh(camera)


## Works out the dirty chunks' arrows and, if the chunks in view or any arrows changed, fills the
## MultiMeshes again.
func refresh(camera: Camera3D) -> void:
	var changed := false
	if _all_dirty:
		_all_dirty = false
		_chunk_arrows.clear()
		_dirty.clear()
		for c in world.chunks:
			_dirty[c] = true
	for c in _dirty:
		_chunk_arrows.erase(c)
		var cv = world.chunks.get(c)
		if cv != null:
			var arrows := chunk_arrows(cv)
			if not arrows.is_empty():
				_chunk_arrows[c] = arrows
		changed = true
	_dirty.clear()
	var planes := camera.get_frustum()
	var shown: Array = []
	for c in _chunk_arrows:
		if AltOverlay._chunk_in_view(c, planes) and (fog == null or fog.seen(Vector2(c) * 32.0 + Vector2(16, 16))):
			shown.append(c)
	var key := str(shown)
	if not changed and key == _shown_key:
		for l in _layers:
			l.visible = l.multimesh.visible_instance_count > 0
		for l in _icon_layers.values():
			(l as MultiMeshInstance3D).visible = (l as MultiMeshInstance3D).multimesh.visible_instance_count > 0
		return
	_shown_key = key
	drawn = 0
	for kind in _layers.size():
		var list: Array = []
		for c in shown:
			list.append_array(_chunk_arrows[c][kind])
		drawn += _fill(_layers[kind], list)
	var by_fluid := {}
	for c in shown:
		var icons: Dictionary = _chunk_arrows[c][ICON]
		for fluid in icons:
			if not by_fluid.has(fluid):
				by_fluid[fluid] = []
			(by_fluid[fluid] as Array).append_array(icons[fluid])
	for fluid in by_fluid:
		if not _icon_layers.has(fluid):
			_icon_layers[fluid] = _icon_layer(str(fluid))
	icons_drawn = 0
	for fluid in _icon_layers:
		icons_drawn += _fill(_icon_layers[fluid], by_fluid.get(fluid, []))


## Fills a MultiMesh with these transforms; how many.
static func _fill(layer: MultiMeshInstance3D, list: Array) -> int:
	var buf := PackedFloat32Array()
	var n := 0
	for t: Transform3D in list:
		buf.append_array([t.basis.x.x, t.basis.y.x, t.basis.z.x, t.origin.x,
			t.basis.x.y, t.basis.y.y, t.basis.z.y, t.origin.y,
			t.basis.x.z, t.basis.y.z, t.basis.z.z, t.origin.z])
		n += 1
	var mm := layer.multimesh
	if mm.instance_count < n:
		mm.instance_count = maxi(n, mm.instance_count * 2)
		buf.resize(mm.instance_count * 12)
	elif mm.instance_count > n:
		buf.resize(mm.instance_count * 12)
	if mm.instance_count > 0:
		mm.buffer = buf
	mm.visible_instance_count = n
	layer.visible = n > 0
	return n


## A fluid's icon layer: its picture flat over everything, as the arrows.
func _icon_layer(fluid: String) -> MultiMeshInstance3D:
	var quad := QuadMesh.new()
	quad.orientation = PlaneMesh.FACE_Y
	quad.size = Vector2.ONE * CursorOverlay.FLUID_ICON
	quad.material = GroundHeight.overlay_material(10, Kit.item_icon(fluid))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visible = false
	add_child(mmi)
	return mmi


## A chunk's arrows by kind, as the settings say.
func chunk_arrows(cv) -> Array:
	var out: Array = [[], [], [], {}]
	var inserters := bool(Settings.get_value("interface", "alt_inserter_arrows"))
	var pumps := bool(Settings.get_value("interface", "alt_pump_arrows"))
	var machines := bool(Settings.get_value("interface", "alt_machine_arrows"))
	var any := false
	for key in cv.entities:
		var r: WorldMirror.Rec = cv.entities[key]
		if r.unit <= 0:
			continue
		var proto = world.protos.entity(r.proto_id)
		if proto == null:
			continue
		var t: String = proto.type
		var wanted := (inserters and t == "inserter") or (pumps and PUMPS.has(t)) \
			or (machines and (CRAFTERS.has(t) or MACHINES.has(t)))
		if not wanted:
			continue
		var x: Dictionary = (model.eprops.get(r.proto_id, {}) as Dictionary).get("x", {})
		var fc = r.extra.get("fc")
		for a in arrows_for(t, x, r.pos, r.dir, int(r.extra.get("fa", 0)), fc if fc is Array else []):
			if int(a[0]) == ICON:
				var fluid := str(a[3])
				if not (out[ICON] as Dictionary).has(fluid):
					out[ICON][fluid] = []
				(out[ICON][fluid] as Array).append(Transform3D(Basis.IDENTITY, Vector3((a[1] as Vector2).x, LIFT * 1.5, (a[1] as Vector2).y)))
			else:
				out[int(a[0])].append(transform(a[1], a[2]))
			any = true
	return out if any else []


## [[kind, at, way], ...] for an entity of `type` at `pos` facing `dir`, from its eprops overlay `x`
## and, for a crafting machine, its recipe's fluid mask `fa` (1 in, 2 out); with its record's `fc` (L10) those
## connections instead, and [ICON, at, way, fluid] for each one's fluid.
static func arrows_for(type: String, x: Dictionary, pos: Vector2, dir: int, fa: int, fc: Array = []) -> Array:
	var out: Array = []
	if CRAFTERS.has(type) and fa != 0 and CursorOverlay.fluid_icons and not fc.is_empty():
		for c in fc:
			if not (c is Array) or c.size() < 5:
				continue
			var way := _turn(Vector2(0, -1), int(c[2]))
			var tile := pos + Vector2(float(c[0]), float(c[1]))
			var flow := str(c[3])
			if flow == "b":
				out.append([FLUID_BOTH, tile + way * 0.5, way])
			else:
				out.append([FLUID, tile + way * 0.5, -way if flow == "i" else way])
			if str(c[4]) != "":
				out.append([ICON, tile - way * 0.05, way, str(c[4])])
		if x.has("vp"):
			var v0 := _turn(_vec(x["vp"]), dir)
			out.append([INDICATION, pos + v0, v0.normalized()])
		return out
	if type == "inserter":
		if x.has("ip") and x.has("id"):
			var pick := _turn(_vec(x["ip"]), dir)
			var drop := _turn(_vec(x["id"]), dir)
			out.append([INDICATION, pos + pick, (drop - pick).normalized()])
			out.append([INDICATION, pos + drop, (drop - pick).normalized()])
		return out
	var crafter := CRAFTERS.has(type)
	var pump := PUMPS.has(type)
	for c in x.get("fb", []):
		if not (c is Array) or c.size() < 4:
			continue
		var flow := str(c[3])
		if crafter and not ((flow == "i" and fa & 1) or (flow == "o" and fa & 2) or (flow == "b" and fa != 0)):
			continue
		if pump and flow == "i":
			continue  # Factorio shows a pump's arrow where its fluid leaves
		var way := _turn(Vector2(0, -1), int(c[2]) + dir)
		var at := pos + _turn(Vector2(float(c[0]), float(c[1])), dir) + way * 0.5
		if flow == "b":
			out.append([FLUID_BOTH, at, way])
		else:
			out.append([FLUID, at, -way if flow == "i" else way])
	if crafter and x.has("vp"):
		var v := _turn(_vec(x["vp"]), dir)
		out.append([INDICATION, pos + v, v.normalized()])
	return out


## Lying flat at `at`, the sprite's top (north) turned to point along `way`.
static func transform(at: Vector2, way: Vector2) -> Transform3D:
	var yaw := atan2(-way.x, -way.y)  # north (0, -1) -> 0, east (1, 0) -> -PI/2, as Godot turns about +Y
	return Transform3D(Basis(Vector3.UP, yaw), Vector3(at.x, LIFT, at.y))


static func _turn(v: Vector2, dir: int) -> Vector2:
	return v.rotated(float(dir) / 16.0 * TAU)


static func _vec(v) -> Vector2:
	return Vector2(float(v[0]), float(v[1])) if v is Array and v.size() >= 2 else Vector2.ZERO
