extends RefCounted
## How high the character stands at a ground point: the drawn top of a belt, underground belt,
## splitter, loader, pipe-to-ground, heat pipe or ground rail there (Factorio's character walks over
## these: they share no collision layer with it), the highest where several meet; 0 for bare ground and
## anything else. The add-on API's api.world.stand_height_at (addon_world.gd) gives this full answer;
## the core's belt step-up (avatar.gd, owner: "stepping onto belts", drawn only) asks for BELTS alone
## and caps it.
##
## The model's top once it is in, else its placeholder's (AimPick.height_of, cached per prototype).
## From the prototype types only: a mod that changes what the character collides with isn't seen.
## A few box tests a call (world.gd's pick index).

const AimPick := preload("res://scripts/world/aim_pick.gd")

## The types Factorio's character walks over (data/core/lualib/collision-mask-defaults.lua: belts(),
## building_walkable(), heat pipes, ground rails).
const WALK_ON := {"transport-belt": true, "underground-belt": true, "splitter": true, "lane-splitter": true,
	"loader": true, "loader-1x1": true, "linked-belt": true, "pipe-to-ground": true, "heat-pipe": true,
	"straight-rail": true, "half-diagonal-rail": true, "curved-rail-a": true, "curved-rail-b": true,
	"legacy-straight-rail": true, "legacy-curved-rail": true}

## The belt family, all the core's step-up stands on (pipes-to-ground, heat pipes and rails are walked
## past at ground level, as Factorio draws the character over them).
const BELTS := {"transport-belt": true, "underground-belt": true, "splitter": true, "lane-splitter": true,
	"loader": true, "loader-1x1": true, "linked-belt": true}


## Tiles over the ground at `point` (x east, y south), over the `types` there (WALK_ON's by default); 0
## without a world or its pick index.
static func at(world, point: Vector2, types: Dictionary = WALK_ON) -> float:
	if world == null or not world.has_method("recs_at"):
		return 0.0
	var best := 0.0
	for r in world.recs_at(point):
		var proto = world.protos.entity(r.proto_id)
		if proto != null and types.has(proto.type):
			best = maxf(best, AimPick.height_of(world, r))
	return best
