extends RefCounted
## Shared wire-format conversion and safe Variant array helpers for the Godot client.


## Returns `v` as an Array when it is one, else an empty Array (for JSON `{}` / null).
static func array(v: Variant) -> Array:
	return v if v is Array else []


## Converts a 16-way Factorio direction into Godot Y-axis yaw (radians).
static func direction_yaw(dir: int) -> float:
	return -float(dir) / 16.0 * TAU


## Converts a normalized Factorio orientation [0, 1) into Godot Y-axis yaw (radians).
static func orientation_yaw(ori: float) -> float:
	return -ori * TAU


## Converts a 1/256-tile fixed-point integer coordinate into tiles.
static func tile(fixed: int) -> float:
	return float(fixed) / 256.0
