extends RefCounted
## True while --stutter-probe reads the client's own timings and counts: world.gd's prof (with
## anim.gd's and far_chunks.gd's shares of it), chunk_view.gd's counters and bridge.gd's slow
## messages are kept only then, so a normal game doesn't time each animated group every frame.
static var on := false

## Main-thread times (µs) of the scripts' once-a-join work, by key, kept only while `on` (the probe
## shows a frame's share of each as w_<key>, and join_hitches.py names them): movers' (mv_*),
## decoratives' (dc_*), ground items' (gi_*), terrain textures' (tt_*).
static var prof := {}


## Adds the time since `t0` (Time.get_ticks_usec()) to `key`.
static func add(key: String, t0: int) -> void:
	if on:
		prof[key] = int(prof.get(key, 0)) + Time.get_ticks_usec() - t0


## Counts of the client's rarer events while `on` (the spike log, debug_overlay.gd, names a slow frame's
## share of each): `dh_palette` Distant Horizon's colour table rebuilt, `item_models` an item model read,
## `hydrated` a chunk filled from the disk cache.
static var counts := {}


static func count(key: String, n := 1) -> void:
	if on:
		counts[key] = int(counts.get(key, 0)) + n


## The slowest message bridge.gd handled since the spike log last looked (once a frame), while `on`:
## [type, µs].
static var slowest_message: Array = ["", 0]


static func note_message(t: String, usec: int) -> void:
	if on and usec > int(slowest_message[1]):
		slowest_message = [t, usec]
