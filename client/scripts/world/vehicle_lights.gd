extends RefCounted
## N1 (V27; owner: "vehicles need their own headlights pointed in front, brighter and wider than the
## player's, and hide the normal flashlight"). Factorio's car, tank and spidertron carry `light`s of
## type "oriented": core/graphics/light-cone.png, the character's flashlight picture, turned with the
## vehicle, shown above darkness 0.3. The car has two, 0.6 tiles either side, 14 ahead, intensity 0.6
## each in a warm yellow; the tank two 0.1 either side, 14 ahead, 0.8 each, near white, splayed
## 0.02 of a turn apart; the spidertron four of different sizes and splays and a round light as the
## character's (base/prototypes/entity/entities.lua, spidertron-animations.lua). Each cone is drawn as
## the character's new flashlight is (avatar.gd beam_texture()): a spot over the ground projecting
## the picture, nothing casting its shadow, scaled by the cone's size and shifted to its place, so two
## overlapping cones light the ground twice as bright and wider than the character's one.
## The bridge doesn't send prototypes' lights, so these are base Factorio's by type (a mod's car takes
## the car's). Shown on the vehicle the character drives or rides in (the bridge doesn't say who
## drives the others). --vehicle-lights=off: none, the character's flashlight as before (avatar.gd).

## Headlights seen from the front (trailer: a tank driving at the camera was a black silhouette).
## Factorio lights a vehicle that someone drives, but the bridge doesn't say who drives which; a car,
## tank or spidertron moving under its own power has a driver, so one that has moved in the last
## HOLD_S seconds lights too (at most MAX_OTHERS besides ours, none casting shadows: the cones'
## projector spots as ours). And each lamp gets a glare: an unshaded additive card at the lens, soft,
## bright looking into the lamp and faint from the side, no light. --headlight-glare=off: only the
## vehicle the character is in lights, no glare (as before).

const Avatar := preload("res://scripts/player/avatar.gd")
const Switches := preload("res://scripts/switches.gd")

static var enabled := Switches.on("--vehicle-lights")
static var glare_enabled := Switches.on("--headlight-glare")
## --headlight-storm=off: the lamps follow the game's darkness alone (a thunderstorm's dimmed sun at dusk
## left them dark on a screen that looks like night).
static var storm_enabled := Switches.on("--headlight-storm")

const HOLD_S := 30.0
const MAX_OTHERS := 6
## Glare card's width in tiles, by type; lamps where the model has no `anim_headlight` part:
## [across, height, ahead] (the car's cones 0.6 either side, the tank's 0.1: one lamp mid-front).
const GLARE := {
	"car": {"size": 1.1, "lamps": [[-0.45, 0.55, 1.0], [0.45, 0.55, 1.0]]},
	"tank": {"size": 1.3, "lamps": [[0.0, 0.8, 1.35]]},
	"spider-vehicle": {"size": 0.9, "lamps": []},
}

static var _glare_shader: Shader
static var _glare_mats := {}

## Per type: cones of [across, ahead, size, intensity, colour, source_orientation_offset] (Factorio's
## shift {across, -ahead}, its size 2 being the character's 25-tile cone), and the round light's
## [size, intensity] or [].
const CAR_YELLOW := Color(0.92, 0.77, 0.3)
const TYPES := {
	"car": {"cones": [[-0.6, 14.0, 2.0, 0.6, CAR_YELLOW, 0.0], [0.6, 14.0, 2.0, 0.6, CAR_YELLOW, 0.0]], "round": []},
	"tank": {"cones": [[-0.1, 14.0, 2.0, 0.8, Color(1.0, 1.0, 0.8), -0.02],
		[0.1, 14.0, 2.0, 0.8, Color(1.0, 1.0, 0.8), 0.02]], "round": []},
	# create_spidertron_light_cone(orientation, intensity, size, shift_adder): shift 14 - adder ahead,
	# size 2 x size, intensity 0.6 x intensity.
	"spider-vehicle": {"cones": [[0.0, 15.0, 2.0, 0.6, CAR_YELLOW, 0.0], [0.0, 11.5, 1.4, 0.42, CAR_YELLOW, -0.05],
		[0.0, 8.5, 0.9, 0.3, CAR_YELLOW, 0.04], [0.0, 7.5, 0.7, 0.36, CAR_YELLOW, 0.06]], "round": [25.0, 0.4]},
}


## The night the lamps go by: the game's, or what the weather's dimmed sun makes of the screen (sun
## energy scale 0.4 reads as 0.48 night), whichever is darker. `wx` is WeatherState.state when active.
static func screen_night(night: float, wx: Dictionary) -> float:
	if not storm_enabled or wx.is_empty():
		return night
	var dim := clampf(1.0 - float(wx.get("sun_energy_scale", 1.0)), 0.0, 1.0)
	return maxf(night, dim * 0.8)


static func has(type: String) -> bool:
	return enabled and TYPES.has(type)


## The type's lights under one node, to be a child of the vehicle's node (forward is -Z), off.
static func build(type: String) -> Node3D:
	var rig := Node3D.new()
	rig.name = "VehicleLights"
	var spec: Dictionary = TYPES[type]
	var old := Avatar.flashlight_mode == "old"
	var texture: ImageTexture = null if old else Avatar.beam_texture()
	for c: Array in spec["cones"]:
		var s := float(c[2]) / 2.0
		var pivot := Node3D.new()
		pivot.rotation.y = -float(c[5]) * TAU
		var spot := SpotLight3D.new()
		spot.light_color = c[4]
		if old:
			# The Compatibility renderer draws no projectors: a plain cone as the locomotives'.
			spot.spot_range = 30.0 * s
			spot.spot_angle = 24.0
			spot.spot_attenuation = 0.4
			spot.position = Vector3(float(c[0]), 2.0, -1.0)
			spot.rotation.x = deg_to_rad(-10.0)
			spot.set_meta("energy", 7.0 * float(c[3]) / 0.6)
		else:
			# The character's cone scaled by s about its spot's foot, the foot put so the cone's middle
			# lands `ahead` tiles in front of the vehicle.
			spot.spot_range = Avatar.BEAM_RANGE * s
			spot.spot_angle = Avatar.BEAM_ANGLE
			spot.spot_angle_attenuation = Avatar.BEAM_EDGE
			spot.spot_attenuation = 0.0
			spot.position = Vector3(float(c[0]), Avatar.BEAM_HEIGHT * s, -(float(c[1]) - Avatar.CONE_AHEAD * s))
			spot.rotation.x = deg_to_rad(-Avatar.BEAM_PITCH)
			spot.light_projector = texture
			spot.shadow_caster_mask = 0  # the projector needs the shadow on; nothing casts into it
			spot.light_specular = 0.25
			spot.set_meta("energy", Avatar.BEAM_PEAK * Avatar.beam_gain() * float(c[3]) / 0.6)
		spot.set_meta("height", spot.position.y)
		spot.shadow_enabled = not old
		spot.light_energy = 0.0
		pivot.add_child(spot)
		rig.add_child(pivot)
	var ring: Array = spec["round"]
	if not ring.is_empty():
		var omni := OmniLight3D.new()
		omni.name = "Round"
		omni.light_color = Color(1.0, 0.86, 0.68)
		# The character's round light (size 25, intensity 0.4) is the lantern's 11 tiles and 1.8.
		omni.omni_range = 11.0 * float(ring[0]) / 25.0
		omni.position = Vector3(0.0, Avatar.LANTERN_HEIGHT, 0.0)
		omni.set_meta("energy", 1.8 * float(ring[1]) / 0.4)
		omni.set_meta("height", Avatar.LANTERN_HEIGHT)
		omni.light_energy = 0.0
		rig.add_child(omni)
	rig.visible = false
	rig.set_meta("kind", type)
	if glare_enabled and spec["cones"].size() > 0:
		rig.set_meta("tint", (spec["cones"][0] as Array)[4])
	return rig


## The glare cards at the lamps: the `anim_headlight` meshes' ends (the node's space, as the rig's),
## else the type's GLARE lamps. Again after the model is dressed anew. Not with --headlight-glare=off.
static func place_glare(rig: Node3D, meshes: Array[MeshInstance3D]) -> void:
	if not glare_enabled or rig == null:
		return
	for child in rig.get_children():
		if child.has_meta("glare"):
			rig.remove_child(child)
			child.queue_free()
	var kind := str(rig.get_meta("kind", ""))
	if not GLARE.has(kind):
		return
	var spec: Dictionary = GLARE[kind]
	var points := lamp_points(meshes)
	if points.is_empty():
		for l: Array in spec["lamps"]:
			points.append(Vector3(float(l[0]), float(l[1]), -float(l[2])))
	var tint: Color = rig.get_meta("tint", Color(1.0, 0.95, 0.8))
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var size := float(spec["size"])
	for i in points.size():
		var card := MeshInstance3D.new()
		card.name = "Glare%d" % i
		card.mesh = quad
		card.material_override = glare_material(tint)
		card.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		card.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		card.position = points[i]
		card.scale = Vector3(size, size, size)
		card.set_meta("glare", true)
		card.set_meta("height", points[i].y)
		card.set_instance_shader_parameter("glow", 0.0)
		rig.add_child(card)


## Where the lenses are: each headlight mesh's front face, at its two ends when it is wide (one mesh
## for both lamps), else its middle.
static func lamp_points(meshes: Array[MeshInstance3D]) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for mi in meshes:
		if not is_instance_valid(mi) or mi.mesh == null:
			continue
		var box: AABB = mi.transform * mi.mesh.get_aabb()
		var front := box.position.z  # forward is -Z
		var mid := box.get_center()
		var r := minf(box.size.y, box.size.x * 0.25) * 0.5
		if box.size.x > 0.5:
			out.append(Vector3(box.position.x + r, mid.y, front))
			out.append(Vector3(box.end.x - r, mid.y, front))
		else:
			out.append(Vector3(mid.x, mid.y, front))
	return out


static func glare_material(tint: Color) -> ShaderMaterial:
	var key := tint.to_html(false)
	if _glare_mats.has(key):
		return _glare_mats[key]
	if _glare_shader == null:
		_glare_shader = Shader.new()
		_glare_shader.code = GLARE_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _glare_shader
	mat.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b).lerp(Vector3.ONE, 0.35))
	_glare_mats[key] = mat
	return mat


static func glares_of(rig: Node3D) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if rig == null:
		return out
	for child in rig.get_children():
		if child.has_meta("glare"):
			out.append(child as MeshInstance3D)
	return out


## A card facing the camera, pulled towards it only when viewed from the front so the body doesn't
## cut it, its node's -Z the lamp's forward: fades smoothly to zero when viewed from the side or
## behind so glare never bleeds through the hull, with soft halo and horizontal streak looking into
## the lamp. Additive, no fog (fog would add its colour), no depth write.
const GLARE_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, skip_vertex_transform, fog_disabled, shadows_disabled;

instance uniform float glow = 0.0;
uniform vec3 tint = vec3(1.0, 0.95, 0.8);
uniform float pull = 0.7;

varying float facing;

void vertex() {
	vec3 centre = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 fwd = normalize((MODELVIEW_MATRIX * vec4(0.0, 0.0, -1.0, 0.0)).xyz);
	vec3 to_cam = normalize(-centre);
	facing = clamp(dot(fwd, to_cam), 0.0, 1.0);
	float front_pull = pull * smoothstep(0.0, 0.35, facing);
	float size = length(MODEL_MATRIX[0].xyz);
	VERTEX = centre + to_cam * front_pull + vec3(VERTEX.xy * size * (0.5 + 0.5 * facing), 0.0);
	NORMAL = vec3(0.0, 0.0, 1.0);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float fall = max(0.0, 1.0 - r);
	float f = facing * facing;
	float front = smoothstep(0.0, 0.25, facing);
	float core = pow(fall, 6.0) * front * (0.35 + 0.65 * f);
	float halo = pow(fall, 2.5) * 0.22 * f;
	float streak = pow(max(0.0, 1.0 - abs(p.y) * 10.0), 2.0) * pow(max(0.0, 1.0 - abs(p.x)), 2.0) * 0.18 * f;
	ALBEDO = tint * glow * (core * 1.6 + halo + streak);
}
"""


## `beam`: how much they show (Avatar.beam of the night, 0 when nobody of ours is in it). `ground`:
## the hills' height under the vehicle over its node's.
static func apply(rig: Node3D, beam: float, ground: float) -> void:
	rig.visible = beam > 0.01
	if not rig.visible:
		return
	for light in lights_of(rig):
		light.light_energy = float(light.get_meta("energy")) * beam
		light.position.y = float(light.get_meta("height")) + ground
	for card in glares_of(rig):
		card.set_instance_shader_parameter("glow", clampf(beam, 0.0, 1.0))
		card.position.y = float(card.get_meta("height")) + ground


static func lights_of(rig: Node3D) -> Array[Light3D]:
	var out: Array[Light3D] = []
	for child in rig.get_children():
		if child is Light3D:
			out.append(child)
		for grand in child.get_children():
			if grand is Light3D:
				out.append(grand)
	return out
