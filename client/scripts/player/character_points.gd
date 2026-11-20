extends RefCounted
## (Add-on API 1.7) The names add-ons attach things to and pose (api.character attach, frame, set_pose):
## 11 bones and 12 points, promised for all of add-on API version 1 (docs/ADDONS.md). They are the
## standard humanoid vocabulary (Godot's SkeletonProfileHumanoid, VRM) less the hands and feet, mapped
## onto the rig's own bone names by BONES, so a later rig or tool may rename its bones.
##
## A bone's frame is its joint (the bone's head), in the model's axes at rest: -z forward, y up, x the
## character's right. A point is a frame carried by a bone, in the same axes, except the hands: there
## -z runs along the forearm past the hand and y faces forward at rest (Zenith's own gun's frame,
## avatar.gd _animate). `muzzle` and `view` are carried by no bone (avatar.gd, camera_rig.gd).

const CharacterPose := preload("res://scripts/player/character_pose.gd")

## API name -> the rig's bone (the same in all four looks: creature_rigs.json).
const BONES := {
	"hips": "root", "spine": "spine", "head": "head",
	"right_upper_arm": "upper_arm_r", "left_upper_arm": "upper_arm_l",
	"right_lower_arm": "forearm_r", "left_lower_arm": "forearm_l",
	"right_upper_leg": "thigh_r", "left_upper_leg": "thigh_l",
	"right_lower_leg": "shin_r", "left_lower_leg": "shin_l",
}
const POINTS := ["head_top", "eyes", "back", "chest", "right_hip", "left_hip", "right_hand", "left_hand",
	"right_foot", "left_foot", "muzzle", "view"]
## The point -> the rig bone that carries it (muzzle and view have none).
const CARRIED_BY := {"head_top": "head", "eyes": "head", "back": "spine", "chest": "spine",
	"right_hip": "root", "left_hip": "root", "right_hand": "forearm_r", "left_hand": "forearm_l",
	"right_foot": "shin_r", "left_foot": "shin_l"}

## How deep the points sit, per look (measured from the models).
const DATA_PATH := "res://data/character_points.json"
static var _data = null


static func is_name(name: String) -> bool:
	return BONES.has(name) or POINTS.has(name)


## Every promised name, the bones first.
static func names() -> Array:
	return BONES.keys() + POINTS


## The rig bone carrying `name` and the frame at rest it carries (the model's frame), as
## [bone, Transform3D]; [] for a name not carried by a bone (unknown, muzzle, view) or a rig without it.
static func rest(pose: CharacterPose, look: String, name: String) -> Array:
	if BONES.has(name):
		var b: String = BONES[name]
		return [b, Transform3D(Basis.IDENTITY, pose.head_of(b))] if pose.index.has(b) else []
	var bone: String = CARRIED_BY.get(name, "")
	if bone == "" or not pose.index.has(bone):
		return []
	var d := depths(pose, look)
	var at := Vector3.ZERO
	var basis := Basis.IDENTITY
	match name:
		"head_top":
			at = pose.tail_of("head")
		"eyes":
			at = pose.head_of("head").lerp(pose.tail_of("head"), float(d["eye_height"])) + Vector3(0.0, 0.0, -float(d["eyes"]))
		"back", "chest":
			var mid := pose.head_of("spine").lerp(pose.tail_of("spine"), 0.5)
			at = mid + Vector3(0.0, 0.0, float(d["back"]) if name == "back" else -float(d["chest"]))
		"right_hip", "left_hip":
			var thigh := "thigh_r" if name == "right_hip" else "thigh_l"
			at = pose.head_of(thigh) + Vector3(float(d["hip"]) * (1.0 if name == "right_hip" else -1.0), 0.0, 0.0)
		"right_hand", "left_hand":
			at = pose.tail_of(bone)
			basis = Basis(Vector3.RIGHT, -PI / 2.0)
		_:
			at = pose.tail_of(bone)  # the feet: the shins' tails
	return [bone, Transform3D(basis, at)]


## The depths for `look` (character_points.json), or ones worked out from its bones: the back and
## chest a share of the height, the eyes of the head's length, the hips of the thighs' spread.
static func depths(pose: CharacterPose, look: String) -> Dictionary:
	if _data == null:
		_data = {}
		var f := FileAccess.open(DATA_PATH, FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				_data = parsed
	var out := {"back": 0.0, "chest": 0.0, "eyes": 0.0, "eye_height": 0.5, "hip": 0.0}
	if pose.index.has("head") and pose.index.has("thigh_r"):
		var height := pose.tail_of("head").y
		out["back"] = height * 0.18
		out["chest"] = height * 0.11
		out["eyes"] = pose.head_of("head").distance_to(pose.tail_of("head")) * 0.36
		out["hip"] = absf(pose.head_of("thigh_r").x) * 0.8
	var own = (_data as Dictionary).get(look)
	if own is Dictionary:
		for k in out:
			if own.has(k):
				out[k] = float(own[k])
	return out
