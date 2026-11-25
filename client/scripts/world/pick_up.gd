extends RefCounted
## F's pick-up as the bridge says it (`pku`, issue #18): {t: "pku", k: tick, l: [[item, count, x, y, lane key,
## unique id, left, item id], ...]}, each item the character took that tick, from the ground (lane key 0) or
## a belt. main.gd hides those off the ground (ground_items.gd), flies them all to the character
## (factorio_ui.gd picked) and hands those off a belt to the belt layer as an inserter's picks.

const Switches := preload("res://scripts/switches.gd")

## The `ie` kind for a hand's pick (inserter_arms.gd EV_PICKED).
const EV_PICKED := 1

## --pickup-hide-now=on (the default) | off: the belt items a `pku` names (the game's unique ids) are hidden from the
## drawn belt in the belt layer's next job, as they start flying (`hu` in the message below; a packed lane the
## lattice draws gets its take's hole from the drawn tick); off, as before: they left the drawn belt only when the
## drawn clock, about half a second behind, reached the take.
static var hide_now := Switches.on("--pickup-hide-now")


## The items taken off a belt (all of each: `left` 0) as an `ie` message of picks by no inserter (unit 0), on
## the message's tick, at the item's place then: belt_items.gd takes each off its simulated lane the way it
## takes an inserter's pick (BeltSim.take_at: the item of that kind nearest the place, on that tick), so the
## items behind it go on as they do behind a hand's take. `a` counts up from 1 within the message, so each
## record is its own pick of one (belt_items.gd's count since the last, and its once-each key). {} for none.
static func belt_takes(msg: Dictionary) -> Dictionary:
	var k := int(msg.get("k", 0))
	var flat: Array = []
	var hide: Array = []
	var l = msg.get("l")
	if not (l is Array):
		return {}
	for r in l:
		if not (r is Array) or r.size() < 8:
			continue
		var key := int(r[4])
		if key <= 0 or int(r[5]) <= 0 or int(r[6]) != 0:
			continue
		flat.append_array([EV_PICKED, 0, k, flat.size() / 9 + 1, int(r[7]), 0, int(r[2]), int(r[3]), key / 8])
		hide.append(int(r[5]))
	if flat.is_empty():
		return {}
	var out := {"t": "ie", "k": k, "n": 1, "p": 2, "l": flat}
	if hide_now:
		out["hu"] = hide
	return out


## Where each item taken off the ground lay (1/256 tile, as `gi` has it), all of it taken.
static func ground_spots(msg: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var l = msg.get("l")
	if not (l is Array):
		return out
	for r in l:
		if r is Array and r.size() >= 8 and int(r[4]) == 0 and int(r[6]) == 0:
			out.append(Vector2i(int(r[2]), int(r[3])))
	return out
