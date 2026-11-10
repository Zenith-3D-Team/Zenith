extends RefCounted
## True while --stutter-probe reads the client's own timings and counts: world.gd's prof (with
## anim.gd's and far_chunks.gd's shares of it), chunk_view.gd's counters and bridge.gd's slow
## messages are kept only then, so a normal game doesn't time each animated group every frame.
static var on := false
