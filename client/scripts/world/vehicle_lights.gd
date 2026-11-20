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

const Avatar := preload("res://scripts/player/avatar.gd")

static var enabled := not ("--vehicle-lights=off" in OS.get_cmdline_user_args())

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
	return rig


## `beam`: how much they show (Avatar.beam of the night, 0 when nobody of ours is in it). `ground`:
## the hills' height under the vehicle over its node's.
static func apply(rig: Node3D, beam: float, ground: float) -> void:
	rig.visible = beam > 0.01
	if not rig.visible:
		return
	for light in lights_of(rig):
		light.light_energy = float(light.get_meta("energy")) * beam
		light.position.y = float(light.get_meta("height")) + ground


static func lights_of(rig: Node3D) -> Array[Light3D]:
	var out: Array[Light3D] = []
	for child in rig.get_children():
		if child is Light3D:
			out.append(child)
		for grand in child.get_children():
			if grand is Light3D:
				out.append(grand)
	return out
