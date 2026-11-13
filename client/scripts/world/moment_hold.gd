extends RefCounted
## A screenshot's moment (addon_host.gd _shoot): from the moment the shot is asked for until the
## picture is taken, Zenith's own view of time stands still, so the picture is of that moment however
## long the view's far chunks take to come. The game itself runs on meanwhile (the bridge reads one
## chunk a tick and sends almost nothing while the game is held at its slowest speed, so it is held
## only for the picture's last frames: shot_pause.gd).
##
## While it is on:
## - the bridge's updates of moving things (`HELD_TYPES`) wait in Bridge instead of being handled, in
##   the order they came, and are handled after it in that order (delta-coded lists stay whole), a
##   frame's message budget at a time, so the view catches up with the game;
## - the drawn clocks stand still: game_clock.gd (movers, robots, trains, vehicles, creatures, the
##   character, belt items, a platform's planet), anim.gd (machines' moving parts and lights),
##   mover_records.gd's idle clock, the sky's time of day and darkness (main.gd), and effects
##   (sprite_fx.gd: smoke, fire and explosions hold where they are; fx.gd starts none).
## Chunks, buildings and their states still come and are drawn as they arrive.

## What waits: movers, belt items (and their far icons, freshness, quality), inserter hands, items
## on the ground, shots, beams, fires and clouds, turrets, enemies' targets, demolishers, spider and
## pentapod feet, asteroids, collectors, cargo pods, lightning, trains, robots' cargo, health bars,
## deaths and hits.
const HELD_TYPES := {
	"mv": true, "bi": true, "bf": true, "bq": true, "bfar": true, "ih": true, "gi": true,
	"pj": true, "gf": true, "shot": true, "afx": true, "died": true, "ts": true, "tf": true, "en": true,
	"seg": true, "legs": true, "ach": true, "acol": true, "cp": true, "lt": true, "tr": true, "rc": true,
	"hp": true,
}

static var on := false


static func begin() -> void:
	if on:
		return
	on = true
	Bridge.hold_types(HELD_TYPES)


## Time runs again; what the bridge sent meanwhile is handled over the next frames.
static func end() -> void:
	if not on:
		return
	on = false
	Bridge.hold_types({})
