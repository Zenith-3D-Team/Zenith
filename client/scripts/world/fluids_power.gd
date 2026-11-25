extends Node3D
## Fluids and power from the mod: what is in each fluid box near the camera (`fl`) and which
## machines are short of power (`pw`), shown the way Factorio shows them: a blinking red
## lightning icon over a machine with no power, a level window on storage tanks in the fluid's
## colour, and a line under the cursor naming the hovered entity's fluid and amount. Low power
## has no icon, as in Factorio (a brownout only slows machines; the entity info says "Low power"):
## drawing one put lightning over machines Factorio shows as fine. Machines no pole reaches get
## Factorio's unplugged icon from the alerts (alert_icons.gd). Wires between poles are wires.gd.

const WorldMirror := preload("res://scripts/world/world.gd")
const ProtoDB := preload("res://scripts/world/protos.gd")
const Visuals := preload("res://scripts/world/visuals.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const Looks := preload("res://scripts/world/looks.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")
const InterfaceState := preload("res://scripts/ui/interface_state.gd")
const LocaleNames := preload("res://scripts/world/locale_names.gd")
const GroundHeight := preload("res://scripts/world/ground_height.gd")
## The red no-power alert, depth tested like alert_icons.gd's (no flicker, hidden behind buildings).
const IconShader := preload("res://shaders/billboard_icon_cut.gdshader")
const PipeFluidShader := preload("res://shaders/pipe_fluid.gdshader")
const Switches := preload("res://scripts/switches.gd")

## Off unless --tank-window=on: the level window on storage tanks (the owner asked for it gone).
static var tank_windows := Switches.has("--tank-window=on")
## On unless --pipe-fluids=off: fluid shown inside windowed straight pipes.
static var pipe_fluids := Switches.on("--pipe-fluids")

const NO_POWER := 0
## Low power: no icon (Factorio draws none), but the entity info's status and dimmer lamps.
const LOW_POWER := 1
## Not connected to any pole: alert_icons.gd draws Factorio's unplugged icon from the alerts.
const NOT_CONNECTED := 2
## Factorio draws its 64-pixel alert pictures at half size: 32 pixels, one tile.
const ICON_SIZE := 1.0
## Factorio's no-power icon blinks: seconds per blink.
const BLINK := 1.0
## A storage tank's window: width and height in tiles, and how far up its middle is, as a
## share of the tank's height.
const WINDOW_SIZE := Vector2(0.42, 1.1)
const WINDOW_MIDDLE := 0.5

var world: WorldMirror
## The player input, for the hovered entity (`hovered`).
var input: Node
## unit -> [{"box", "fluid", "amount", "capacity", "temperature"}, ...]
var fluids := {}
## unit -> 0 (no power), 1 (low power) or 2 (not connected); machines with enough power aren't listed.
var unpowered := {}
## unit -> temperature (°C) of heat pipes, reactors and heat interfaces (`ht`).
var heat := {}

var _incoming := {"fl": {}, "pw": {}, "ht": {}}
var _frame := {"fl": -1, "pw": -1, "ht": -1}
var _icons: MultiMeshInstance3D  # the no-power icons
## Where the no-power icons are drawn (tests).
var icon_spots: Array[Transform3D] = []
## [Transform3D, linear Color, fill] for each drawn pipe fluid column (tests, since headless Dummy drops MultiMesh data).
var pipe_fluid_spots: Array = []
var _windows: MultiMeshInstance3D
var _pipe_fluids: MultiMeshInstance3D
var _pipe_cavities := {}  # [Mesh, horizontal] -> {"cy", "r", "half_len"}
var _wired_world: WorldMirror
var _label := Label.new()
var _visuals_dirty := false
var _icons_dirty := false
var _windows_dirty := false
var _icon_chunks := {}  # Vector2i chunk -> true (chunks currently contributing no-power icons)
var _window_chunks := {}  # Vector2i chunk -> true (chunks currently contributing fluid windows)
var icon_rebuilds := 0  # (tests) how many times _update_icons ran
var window_rebuilds := 0  # (tests) how many times _update_windows ran
var _model_generation := -1

static var _core_textures := {}  # path under data/ -> Texture2D or null


func _ready() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var m := ShaderMaterial.new()
	m.shader = IconShader
	var texture := core_texture("core/graphics/icons/alerts/electricity-icon-red.png")
	m.set_shader_parameter("icon", texture if texture != null else _fallback_texture(Color(0.9, 0.2, 0.15)))
	m.set_shader_parameter("blink_period", BLINK)
	_icons = _multimesh(quad, m, false)
	_icons.add_to_group(InterfaceState.GROUP)  # gone while the interface is hidden (interface_state.gd)
	InterfaceState.follow(_icons)

	var window := BoxMesh.new()
	window.size = Vector3.ONE
	var glass := StandardMaterial3D.new()
	glass.vertex_color_use_as_albedo = true
	glass.roughness = 0.25
	glass.metallic = 0.2
	_windows = _multimesh(window, glass, true)

	var pipe_mat := ShaderMaterial.new()
	pipe_mat.shader = Looks.shader_for(PipeFluidShader)
	_pipe_fluids = _multimesh(_pipe_fluid_mesh(), pipe_mat, true, true)

	var layer := CanvasLayer.new()
	add_child(layer)
	_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.7))
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 4)
	_label.visible = false
	layer.add_child(_label)


func _exit_tree() -> void:
	if is_instance_valid(_wired_world) and _wired_world.entities_changed.is_connected(_on_entities_changed):
		_wired_world.entities_changed.disconnect(_on_entities_changed)
	_wired_world = null


func _multimesh(mesh: Mesh, material: Material, colors: bool, custom := false) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colors
	mm.use_custom_data = custom
	mm.mesh = mesh
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mmi


func reset() -> void:
	fluids.clear()
	unpowered.clear()
	heat.clear()
	_pipe_cavities.clear()
	pipe_fluid_spots.clear()
	_icon_chunks.clear()
	_window_chunks.clear()
	icon_rebuilds = 0
	window_rebuilds = 0
	for t in _frame:
		_frame[t] = -1
		_incoming[t] = {}
	_visuals_dirty = true
	_icons_dirty = true
	_windows_dirty = true


func _chunk_has_any(chunk: Vector2i, table: Dictionary) -> bool:
	if world == null or table.is_empty():
		return false
	var cv = world.chunks.get(chunk)
	if cv == null:
		return false
	for rec in cv.entities.values():
		if table.has(rec.unit):
			return true
	return false


func _on_entities_changed(chunk: Vector2i) -> void:
	if _icon_chunks.has(chunk) or _chunk_has_any(chunk, unpowered):
		_icons_dirty = true
	if _window_chunks.has(chunk) or _chunk_has_any(chunk, fluids):
		_windows_dirty = true


## True when the machine has no power or isn't connected (low power counts as powered, dimly).
func has_no_power(unit: int) -> bool:
	var state := int(unpowered.get(unit, -1))
	return state == NO_POWER or state == NOT_CONNECTED


func power_state(unit: int) -> int:
	return int(unpowered.get(unit, -1))


## One part of `fl` ([unit, box, fluid id, amount, capacity, temperature, ...]), `pw`
## ([unit, 0|1|2, ...]) or `ht` ([unit, temperature, ...]); a complete update replaces the last.
func handle(msg: Dictionary) -> void:
	var t := str(msg.get("t", ""))
	if not _frame.has(t):
		return
	var k := int(msg.get("k", 0))
	if k != int(_frame[t]):
		_frame[t] = k
		_incoming[t] = {}
	var into: Dictionary = _incoming[t]
	var list = msg.get("l")
	if list is Array:
		if t == "fl":
			var i := 0
			while i + 5 < list.size():
				var unit := int(list[i])
				if not into.has(unit):
					into[unit] = []
				(into[unit] as Array).append({"box": int(list[i + 1]), "fluid": world.protos.fluid_name(int(list[i + 2])),
					"amount": int(list[i + 3]), "capacity": int(list[i + 4]), "temperature": int(list[i + 5])})
				i += 6
		else:
			var i := 0
			while i + 1 < list.size():
				into[int(list[i])] = int(list[i + 1])
				i += 2
	if int(msg.get("part", 1)) < int(msg.get("parts", 1)):
		return
	if t == "fl":
		fluids = into
		_windows_dirty = true
	elif t == "ht":
		heat = into
		if world != null and world.animator != null:
			world.animator.heat_changed(heat)
	else:
		unpowered = into
		_icons_dirty = true
	_incoming[t] = {}


func _process(_delta: float) -> void:
	InterfaceState.follow(_icons)
	if world == null:
		return
	if _wired_world != world:
		if is_instance_valid(_wired_world) and _wired_world.entities_changed.is_connected(_on_entities_changed):
			_wired_world.entities_changed.disconnect(_on_entities_changed)
		_wired_world = world
		if not world.entities_changed.is_connected(_on_entities_changed):
			world.entities_changed.connect(_on_entities_changed)
	if _model_generation != ModelLibrary.generation:
		_model_generation = ModelLibrary.generation  # tops of models that were still being made
		_pipe_cavities.clear()
		_icons_dirty = true
		_windows_dirty = true
	if _visuals_dirty:
		_visuals_dirty = false
		_icons_dirty = true
		_windows_dirty = true
	if _icons_dirty:
		_icons_dirty = false
		_update_icons()
	if _windows_dirty:
		_windows_dirty = false
		_update_windows()
	_update_label()


## Icons sit just above the machine, like Factorio's alerts over the entity; only for no power.
func _update_icons() -> void:
	icon_rebuilds += 1
	_icon_chunks.clear()
	var list: Array[Transform3D] = []
	for unit in unpowered:
		var rec: WorldMirror.Rec = world.entities.get(unit)
		if rec == null or int(unpowered[unit]) != NO_POWER:
			continue
		_icon_chunks[rec.chunk] = true
		var top := entity_top(rec)
		list.append(Transform3D(Basis.from_scale(Vector3.ONE * ICON_SIZE), Vector3(rec.pos.x, top + 0.25 + ICON_SIZE * 0.5, rec.pos.y)))
	icon_spots = list
	var mm := _icons.multimesh
	mm.instance_count = list.size()
	for i in list.size():
		mm.set_instance_transform(i, list[i])


## How many no-power icons are drawn (tests).
func icon_count() -> int:
	return _icons.multimesh.instance_count if _icons != null else 0


## How many windowed pipe fluid columns are drawn (tests).
func pipe_fluid_count() -> int:
	return _pipe_fluids.multimesh.instance_count if _pipe_fluids != null else 0


## Storage tanks show how full they are through a window on their south face (the side the
## camera looks at), the fluid's colour rising behind dark glass; windowed straight pipes show a
## flowing column inside their glass window.
func _update_windows() -> void:
	window_rebuilds += 1
	_window_chunks.clear()
	var xforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	var pipe_xforms: Array[Transform3D] = []
	var pipe_colors: Array[Color] = []
	var pipe_custom: Array[Color] = []
	var want_pipes := pipe_fluids and ModelLibrary.pipe_windows
	for unit in fluids:
		var rec: WorldMirror.Rec = world.entities.get(unit)
		if rec == null:
			continue
		var proto: ProtoDB.EntityProto = world.protos.entity(rec.proto_id)
		if proto == null:
			continue
		var box: Dictionary = (fluids[unit] as Array)[0]
		if proto.type == "storage-tank":
			if not tank_windows:
				continue
			_window_chunks[rec.chunk] = true
			var fill := clampf(float(box["amount"]) / maxf(float(box["capacity"]), 1.0), 0.0, 1.0)
			var top := entity_top(rec)
			var face := _south_face(rec, proto)
			var middle := top * WINDOW_MIDDLE
			var size := Vector2(WINDOW_SIZE.x, minf(WINDOW_SIZE.y, top * 0.6))
			# Over an add-on's hills (ground_height.gd), as the tank's model is lifted in its shader.
			var at := Vector3(rec.pos.x, middle + GroundHeight.at(rec.pos.x, face), face)
			xforms.append(Transform3D(Basis.from_scale(Vector3(size.x + 0.08, size.y + 0.08, 0.03)), at))
			colors.append(Color(0.08, 0.09, 0.1))
			if fill > 0.0:
				var h := size.y * fill
				var fluid_color: Color = world.protos.fluid_colors.get(str(box["fluid"]), Color(0.3, 0.5, 0.8))
				xforms.append(Transform3D(Basis.from_scale(Vector3(size.x, h, 0.03)), at + Vector3(0.0, (h - size.y) * 0.5, 0.012)))
				# Dark fluids (crude oil) stay dark but still read against the black glass.
				colors.append(fluid_color.lerp(Color.WHITE, 0.08))
		elif want_pipes and proto.type == "pipe" and rec.extra.has("pw"):
			_window_chunks[rec.chunk] = true
			var pc := int(rec.extra.get("pc", 0)) & 15
			if not (pc in [5, 10]):
				continue
			if not ModelLibrary.model_name(proto.name, proto.type, rec.extra, rec.dir).ends_with("-window"):
				continue
			var mesh := world.ready_mesh(proto, rec)
			if mesh == null:
				continue
			var fluid_name := str(box.get("fluid", ""))
			if fluid_name == "":
				continue
			var amount := float(box["amount"])
			var capacity := maxf(float(box["capacity"]), 1.0)
			var fill := clampf(amount / capacity, 0.08, 1.0) if amount > 0.0 else 0.06
			var horizontal := pc == 10
			var cav := _pipe_cavity(mesh, horizontal)
			var rot := Basis(Vector3.UP, PI * 0.5) if horizontal else Basis.IDENTITY
			var basis := rot * Basis.from_scale(Vector3(float(cav["r"]), float(cav["r"]), float(cav["half_len"]) * 2.0))
			pipe_xforms.append(Transform3D(basis, Vector3(rec.pos.x, float(cav["cy"]), rec.pos.y)))
			var fc: Color = world.protos.fluid_colors.get(fluid_name, Color(0.3, 0.5, 0.8))
			pipe_colors.append(fc.srgb_to_linear())
			pipe_custom.append(Color(fill, 0.0, 0.0, 0.0))
	var mm := _windows.multimesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, colors[i])
	if _pipe_fluids != null:
		pipe_fluid_spots.clear()
		var pmm := _pipe_fluids.multimesh
		pmm.instance_count = pipe_xforms.size()
		for i in pipe_xforms.size():
			pmm.set_instance_transform(i, pipe_xforms[i])
			pmm.set_instance_color(i, pipe_colors[i])
			pmm.set_instance_custom_data(i, pipe_custom[i])
			pipe_fluid_spots.append([pipe_xforms[i], pipe_colors[i], pipe_custom[i].r])


## Unit horizontal Z-axis cylinder (radius 1, z in [-0.5, +0.5], 24 segments) with closed end caps,
## clockwise front-face winding for Godot cull_back.
static func _pipe_fluid_mesh() -> ArrayMesh:
	const SEGS := 24
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	for i in SEGS + 1:
		var a := float(i) * TAU / float(SEGS)
		var c := cos(a)
		var s := sin(a)
		verts.append(Vector3(c, s, -0.5))
		norms.append(Vector3(c, s, 0.0))
		verts.append(Vector3(c, s, 0.5))
		norms.append(Vector3(c, s, 0.0))
	for i in SEGS:
		var b := i * 2
		idx.append(b)
		idx.append(b + 1)
		idx.append(b + 3)
		idx.append(b)
		idx.append(b + 3)
		idx.append(b + 2)
	var f_center := verts.size()
	verts.append(Vector3(0.0, 0.0, 0.5))
	norms.append(Vector3(0.0, 0.0, 1.0))
	for i in SEGS:
		var a := float(i) * TAU / float(SEGS)
		verts.append(Vector3(cos(a), sin(a), 0.5))
		norms.append(Vector3(0.0, 0.0, 1.0))
	for i in SEGS:
		var curr := f_center + 1 + i
		var nxt := f_center + 1 + ((i + 1) % SEGS)
		idx.append(f_center)
		idx.append(nxt)
		idx.append(curr)
	var b_center := verts.size()
	verts.append(Vector3(0.0, 0.0, -0.5))
	norms.append(Vector3(0.0, 0.0, -1.0))
	for i in SEGS:
		var a := float(i) * TAU / float(SEGS)
		verts.append(Vector3(cos(a), sin(a), -0.5))
		norms.append(Vector3(0.0, 0.0, -1.0))
	for i in SEGS:
		var curr := b_center + 1 + i
		var nxt := b_center + 1 + ((i + 1) % SEGS)
		idx.append(b_center)
		idx.append(curr)
		idx.append(nxt)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out


static func _is_glass_material(mat: Material) -> bool:
	if mat is BaseMaterial3D:
		return (mat as BaseMaterial3D).transparency != BaseMaterial3D.TRANSPARENCY_DISABLED
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		var sh := sm.shader
		if sh == ModelLibrary.FactorioAlphaShader or sh == Looks.shader_for(ModelLibrary.FactorioAlphaShader):
			return true
		if sm.resource_name.to_lower().contains("glass"):
			return true
	return false


## Inner cylinder centre height, radius, and half-length under a windowed pipe mesh's glass.
func _pipe_cavity(mesh: Mesh, horizontal: bool) -> Dictionary:
	var key := [mesh, horizontal]
	if _pipe_cavities.has(key):
		return _pipe_cavities[key]
	var kept: Variant = mesh.get_meta(ModelLods.ARRAYS_META) if mesh.has_meta(ModelLods.ARRAYS_META) else null
	var any_glass := false
	var axis_min := INF
	var axis_max := -INF
	var cross_min := INF
	var cross_max := -INF
	var y_min := INF
	var y_max := -INF
	for s in mesh.get_surface_count():
		if not _is_glass_material(mesh.surface_get_material(s)):
			continue
		var arrays: Array = kept[s] if kept is Array and s < (kept as Array).size() and (kept as Array)[s] is Array else mesh.surface_get_arrays(s)
		var v_var: Variant = arrays[Mesh.ARRAY_VERTEX] if arrays.size() > Mesh.ARRAY_VERTEX else null
		if not (v_var is PackedVector3Array):
			continue
		for v: Vector3 in (v_var as PackedVector3Array):
			any_glass = true
			var along := v.x if horizontal else v.z
			var across := v.z if horizontal else v.x
			axis_min = minf(axis_min, along)
			axis_max = maxf(axis_max, along)
			cross_min = minf(cross_min, across)
			cross_max = maxf(cross_max, across)
			y_min = minf(y_min, v.y)
			y_max = maxf(y_max, v.y)
	var out: Dictionary
	var aabb := mesh.get_aabb()
	var half_len := 0.36
	if any_glass:
		var win_half := maxf(absf(axis_min), absf(axis_max))
		half_len = clampf(win_half + 0.07, 0.25, 0.42)
		var w := 0.5 * (cross_max - cross_min)
		var h := y_max - y_min
		if h > 0.02 and w > 0.05:
			var r := clampf((w * w + h * h) / (2.0 * h), 0.12, 0.46)
			var cy := clampf(y_max - r, r, 1.2)
			out = {"cy": cy, "r": maxf(r - 0.018, 0.08), "half_len": half_len}
	if out.is_empty():
		var cross_size := aabb.size.z if horizontal else aabb.size.x
		var r_box := clampf(minf(cross_size, aabb.size.y) * 0.36, 0.10, 0.42)
		out = {"cy": maxf(aabb.get_center().y, r_box), "r": r_box, "half_len": half_len}
	_pipe_cavities[key] = out
	return out


func _south_face(rec: WorldMirror.Rec, proto: ProtoDB.EntityProto) -> float:
	var mesh := world.ready_mesh(proto, rec)
	if mesh != null:
		return rec.pos.y + mesh.get_aabb().end.z + 0.02
	var rect := WorldMirror.selection_rect(proto, rec.pos, rec.dir)
	return rect.end.y - rect.size.y * (1.0 - Visuals.SHRINK) * 0.5 + 0.02


## The hovered entity's fluid and power, by the cursor, like the lines in Factorio's entity info.
func _update_label() -> void:
	var rec: WorldMirror.Rec = input.get("hovered") if input != null else null
	if rec == null or rec.unit == 0:
		_label.visible = false
		return
	var lines: PackedStringArray = []
	for box in fluids.get(rec.unit, []):
		var line := "%s: %s / %s" % [LocaleNames.item(str(box["fluid"])), _amount(int(box["amount"])), _amount(int(box["capacity"]))]
		if int(box["temperature"]) != 15:
			line += " at %d °C" % int(box["temperature"])
		lines.append(line)
	if heat.has(rec.unit):
		lines.append("Temperature: %d °C" % int(heat[rec.unit]))
	# Power is the entity info's status line, as in Factorio (entity_info.gd), not this one.
	if lines.is_empty():
		_label.visible = false
		return
	_label.text = "\n".join(lines)
	_label.position = get_viewport().get_mouse_position() + Vector2(18, 18)
	_label.visible = true


## Like Factorio's fluid amounts: 180, 1.5k, 25k.
static func _amount(n: int) -> String:
	if n < 1000:
		return str(n)
	return ("%.1f" % (n / 1000.0)).trim_suffix(".0") + "k"


## The top of the entity as drawn: its full model (body, moving parts and arm rig; for a ghost, the
## entity it will build), or its placeholder box.
func entity_top(rec: WorldMirror.Rec) -> float:
	return entity_top_in(world, rec)


static func entity_top_in(w: WorldMirror, rec: WorldMirror.Rec) -> float:
	if w == null or rec == null:
		return 1.0
	var proto: ProtoDB.EntityProto = w.protos.entity(rec.proto_id)
	if proto == null:
		return 1.0
	if proto.type == "entity-ghost" and rec.extra.has("gh"):
		var inner: ProtoDB.EntityProto = w.protos.entity(int(rec.extra["gh"]))
		if inner != null:
			proto = inner
	var mesh := w.ready_mesh(proto, rec, rec.dir)
	var top := ModelLibrary.top_for_entity(proto.name, proto.type, rec.extra, rec.dir)
	if top <= 0.0:
		top = mesh.get_aabb().end.y if mesh != null else Visuals.height_for(proto)
	if proto.type == "inserter":
		top = maxf(top, 1.15)  # unrigged inserter arms rise above the 0.3 base (inserter_arms.gd)
	return top


## A texture from Factorio's own data folder (`core/graphics/...`), read at runtime from the
## player's install like item icons; null without one. Icons that carry their smaller mipmaps
## to the right (a 120x64 image) are cut to the square on the left.
static func core_texture(path: String) -> Texture2D:
	if _core_textures.has(path):
		return _core_textures[path]
	var texture: Texture2D = null
	var dir := ItemIcons.factorio_data_dir()
	if dir != "" and FileAccess.file_exists(dir.path_join(path)):
		var image := Image.load_from_file(dir.path_join(path))
		if image != null:
			image.convert(Image.FORMAT_RGBA8)
			var h := image.get_height()
			if image.get_width() > h * 3 / 2:
				image = image.get_region(Rect2i(0, 0, h, h))
			image.fix_alpha_edges()  # as GuiAssets: no dark rim in the smaller mipmaps
			image.generate_mipmaps()
			texture = ImageTexture.create_from_image(image)
	_core_textures[path] = texture
	return texture


## Without a Factorio install: a plain disc in the icon's colour.
static func _fallback_texture(color: Color) -> Texture2D:
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var d := Vector2(x - 15.5, y - 15.5).length()
			image.set_pixel(x, y, color if d < 14.0 else Color(0, 0, 0, 0))
	return ImageTexture.create_from_image(image)
