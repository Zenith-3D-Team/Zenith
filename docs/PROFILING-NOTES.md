# Profiling Probes & Deep Optimization Notes

Detailed measurement probes, benchmark investigations, and historical tuning logs moved from [TROUBLESHOOTING.md](TROUBLESHOOTING.md) to keep day-to-day troubleshooting quick to scan. See [SWITCHES.md](SWITCHES.md) for the consolidated CLI `--flag` index.

> **Contents:** [Measuring & Probes](#measuring-the-client) · [Additional Probes & Debug Options](#the-other-probes-and-debug-options) · [Graphics Savings & Switches](#graphics-savings-in-021-and-their-switches) · [Loading Models: Memory & Join Time](#loading-models-memory-and-time-at-a-join) · [CPU, Streaming & GPU Tuning Switches](#cpu-streaming-and-gpu-tuning-switches)

---

### Measuring the client

**Shader refresh** (on by default; `-- --shader-refresh=off` skips it, `--shader-refresh=force` refreshes this start): a new build's first start (a new stamp in `user://build-stamp.txt`: version, Godot, Zenith.exe/.pck size and time in a download, a hash of the shader files from source) deletes `user://shader_cache`, `user://vulkan` and `user://d3d12`, starts the same command line again and ends, so shaders compile fresh once. Never in headless or `--settings-file` runs. From source every shader edit counts as a new build.

**The stall watchdog** (on by default; `-- --stall-watchdog=off`, `--stall-watchdog=<seconds>` for its wait, 5 unless
given; client/scripts/debug/stall_watchdog.gd): a thread that, when no new frame comes for that long, writes
`[stall-watchdog] no new frame for N s (frame F), the main thread last at: <where>` in the log (again every 15 s,
and a line when frames come again). `<where>` is the last crumb the main thread left: a step of main.gd's start
(`main _ready: open_menu`...), the menu backdrop's parts, the part of world.gd's frame after which it stopped
(`world: after <part>`), or `frame start` / `frame end` (every script of the frame done: the engine's own drawing
or the GPU is what waits). For a start that hangs with nothing in the log.

**The spike log** (`-- --spike-log[=ms]`, or the debug menu's Tests → Spike log; off by default;
client/scripts/debug/debug_overlay.gd): every frame slower than the threshold (33 ms unless given) is one
line in `user://debug/spikes.log` (`%APPDATA%\Godot\app_userdata\Zenith\debug\spikes.log`; nothing
leaves the PC; the file is appended to and stops at 8 MB): the seconds since the log started, the frame
split into **scripts** (every `_process`, by the profiler's marks), **deferred+frees** (deferred calls and
freed nodes after the scripts), **draw** (the renderer's frame on the main thread, from
`RenderingServer.frame_pre_draw` to `frame_post_draw`; `-` headless, where nothing is drawn and the
frees fall into the rest) and **rest** (presenting, input, physics, the next frame's start), then the
5 slowest scripts (`top`), world.gd's and the probes' parts over 1 ms (`parts`: `x_optimistic` chunks
filled from the disk cache, `dh_palette` Distant Horizon's colour table, `gi_model_load` item models and
the rest of world.gd's timers), the frame's counts (`counts`: `new_chunk` chunks built, `hydrated`
filled from the disk cache, `dh_palette` palette refreshes, `item_models` read, `far_merges`, `nodes`
made or freed) and the slowest message handled. `Addons` in `top` is the whole add-on host (its own
`_process` and every add-on's node under it); `addons <id> <ms>, ...` after it names the three slowest
add-ons of that frame by their own node's turn (each `Addon_<id>` node and its children, marks round each
one only while the log or the profiler is on; an add-on's signal handlers run in the bucket that emits them,
its `_physics_process` in `rest`). While it runs it turns the client's own timers on
(`Probing.on`, as the stutter probe does: a few µs a frame). The profiler overlay's `Scripts x ms
(peak y)` is now the scripts' own slowest frame of the last second by the same marks; `Main thread peak`
beside it is Godot's process monitor, the main thread's whole frame (scripts, deferred calls and, with
`thread_model=1`, the renderer's draw), which the overlay used to show as the scripts' peak.


`-- --stutter-probe=<out.json>[@route]` (client/scripts/debug/stutter_probe.gd) records every
frame's time and what ran in it, then quits: `@busy` walks through the mock's `--busy` base,
`@fast` runs two laps of a loop round where the character joined (on the owner's save its
exoskeletons make that 30-40 tiles a second), `@stand` stays put, `@variants` with `--probe-variants` (or `--probe-variants=ssao off,trees
hidden`) prices render settings and hides models one kind at a time and lists the models in view.
Variants combine with `+`; `fit [quality] atlas=4096 splits=1 ...` tries sun_shadows.gd's fitting
with other settings, `legacy render` the shadows and levels of detail from before it, `lod
threshold 4`, `lod lines 0` (levels of detail and SSAO in every real line), `relief off` (the ground's
bumps), `shadow distance 60`, `fsr2`, `fsr2 0.5|0.67|0.75|1.0` (AMD FSR 2.2, saving and temporarily
disabling TAA/MSAA/screen-space AA), `arms|items|wires|movers|terrain no shadow` and others (see
`_set_variant`). `@turn` turns the view half round in one frame and back (in first person with
`--camera=first-person`), `@laps` runs `@fast`'s laps then stands 10 s; both record each frame's unload
counts (`--probe-unload` adds them to any route: chunks loaded, drawn, drawn past the square, kept past it,
behind-cull hidden and queued, far merging's queues, the budget's grants); `--probe-unload-walk` also walks
what is drawn every 6 frames (instances in and out of view, past the render distance, draw calls, triangles
and shadow casters by owner; slow on a long view, so leave it out when timing frames), and
`--probe-frame-sleep=<ms>` makes every frame that much slower, as a dense base's are. `--probe-ab=3` measures each variant three times between two "base" steps, which
cancels the graphics card's drift (compare each with the bases beside it), `--probe-timing=2,4`
sets the seconds to settle and to measure, `--probe-stay` leaves the client running after the summary
(a harness that takes screenshots after the route ends it), `--probe-warmup=30` waits longer and until no chunk is
left to build, `--probe-shots=<dir>` saves a screenshot of each step. Each step's medians (frame,
GPU, render CPU, draw calls and triangles of the view and of the shadow passes, casting chunks)
are printed and kept in the JSON's `variants`. `--legacy-render` starts with the shadows and levels
of detail from before sun_shadows.gd, for a whole run. `--soft-shadow-atlas=4096` caps the sun's shadow map at 4096 while the
sun has an angular size (a look's soft shadows, the Cinematic look's): Ultra's 8192 map then stays at
4096 under the look (measured at 4K on the owner's desktop: 1.5 ms less at Ultra under the Cinematic look,
a still the same; nothing at Low and High, whose maps are 4096 or smaller). It is off by default (the
quality's own map, `0` or `off`): close up on the character the soft shadows' edges came out stair-stepped. The variant `soft shadow atlas <size>` sets it for one step (`soft
shadow atlas 0` against `base` under the Cinematic look at Ultra; without soft shadows it changes nothing).
`--shadow-fit=old` fits the sun's shadow map as before the shadows' stability work: whether the view
"reaches far" (Godot's cascades) was judged by the ladder's distance, never under 32 tiles, so zoomed in
the ordinary angled view got cascades (two splits on Low and Medium, half the texels on one axis; four on
High, a hard seam by the character); the ground was measured at y = 0 under a camera riding Terrain
Elevation's hills, so walking over hills flipped the mode or the distance step and every shadow moved;
and the split fractions were set in one-map mode too. Now the far test uses what the view needs (its
furthest ground over the fade, at most the cap) or the horizon in view, the ground is measured from the
height where the screen's centre meets the hills (the furthest 1.5 tiles under it, so valleys keep their
shadows), the shortest distance is 12 tiles and the fractions are set only when there are splits. At a
1920 x 1080 picture, pitch 50, High's 4096 map: zoom 6 one map over 13.8 tiles (about 185 texels a tile;
the old fit four splits to 32 tiles), zoom 15 27.8 tiles (91, was 32 tiles and 79), zoom 30 unchanged
(55.8, 45). Factorio's orthographic view keeps its fixed cascades either way.
`--shadow-filter=old` puts back the soft filters from before the shadows' steps 2-3: Soft Low (4 taps)
on Medium, High and Ultra with fixed blurs (High 0.6 texels), and a look's sun size (the Cinematic look's
1.4 degrees, Godot's PCSS) passed straight to the sun with a 20-tile pancake. Under the Cinematic look
the old picture also needs the add-on's "Shadows soften with distance" on and its "Sun size" at 1.4: the
add-on (0.5.0) hands a sun size of 0 otherwise, so the switch alone gives the old filter without PCSS. Now the blur follows the
map's texels a tile: the edge's radius on the ground (0.02 tiles, a look's `shadow_edge`; 0.04 under
the Cinematic look's Soft shadows) times the nearest split's texels a tile, clamped between one texel and
the filter's own radius (1.5 to 4 texels); Low keeps blur 1.0. A look's sun size (PCSS) is only used when
it asks for one (the Cinematic look's Shadows soften with distance, at its Sun size of 0.5): then blur
1.0, Soft High's 24 + 24 taps on High and Ultra, and a pancake of 8 tiles, which keeps the blocker search
small and dense (`--shadow-pancake=<tiles>` sets it). Anti-aliasing is unchanged: no screen-space AA
(FXAA, SMAA) cleans shadow noise; only TAA and FSR2 average it, and both ghost on belts and inserter
arms, so the filter is made to leave none. `--sun-step=<degrees>` (measuring only; 0, the default, is
smooth) holds the sun's light until it has moved more than that many degrees, then jumps: the shadow map
rests in between; the sky's sun and the passes stay smooth. The stutter probe's variants `sun size
<degrees>` (0.5: PCSS on), `pancake <tiles>` (PCSS's), `blur <x>` (a fixed blur, 0 fitted) and `edge
<tiles>` set these for one step, beside `soft <quality>` (`hard`, `very_low` ... `ultra`; the fitted blur
is worked out for that filter's radius, so the edge on the ground keeps its width).
`@join` measures the join itself: it stands 90 s from the world being ready (pass `--probe-warmup=0`
so the first load's frames are in), notes when the view was fully drawn (the `JOIN` line: chunks,
terrain and models settled, the belts' first load done) and with `--probe-stay` keeps the client
running after writing the file, so `tools/belt_view_check.py --client-arg=--stutter-probe=<out>@join
--client-arg=--probe-warmup=0 --client-arg=--probe-stay` scores the same run. `python
tools/join_hitches.py out.json [--windows] [--md]` then gives frame-time percentiles, the frames over 25
and 50 ms and what each hitch was spent on (the biggest script subtree, world.gd's part of it, the
renderer's draw with the pipelines it compiled, or the wait for the GPU). belt_view_check's
`--godot-arg=--gpu-profile` passes Godot its own flag so the probe also gets the render steps' times.
`@shot` (L14) takes the camera up (`--probe-shot-camera=<height>,<pitch>[,hand]`, default 250 tiles at 22
degrees: past the horizon, about 4,700 of the mock's chunks; `hand` gives the camera back to the player's
view when the shot ends) and a screenshot as the Cinematic camera's F12 does, framed as 1920 x 1080 and
written to the run's own user folder, then stands 10 s (`--probe-shot-after=<s>`): the shot's frames are
the `shot` phase, the `walk` phase is the frames after it, and an `AFTER SHOT second N` line for each second
gives the worst frame, those over 50 ms, the chunks still to free and how many of them are still drawn
(`q_free_drawn`), and the parts that took most (`pre_process` and `after_process`: the frame's time before
the first and after the last `_process`, coroutines, deferred calls, freed nodes, physics and the draw).
`@pan` moves the camera fast while the character stands (the owner's stutter when the camera moves
quickly): 3 s still, the view spun round at 240 degrees a second for 6 s, 2 s still, zoomed all the way out
and back in over 6 s, 2 s still, then the camera taken over as a free camera and flown 360 tiles east at 60
tiles a second and back (12 s), given back, 5 s still. Split the frames by leg with their cumulative times
(3, 9, 11, 17, 19, 31, 36 s). Headless it shows the main thread only; the decorative sheets' bakes
(`decor_sheet_baker.gd`) run only with a GPU, and pipeline compiles only show in a window.
With the separate render thread the renderer's own times are only read with
`--probe-render-times` (each read waits for that thread). `--belt-items-sync` handles belt items on
the main thread instead of a worker, for comparing. `--no-belt-stand-ins` draws every belt whole
(belts drawn under 20 pixels a tile are otherwise light stand-ins, belt_lods.gd), for comparing.
`--far-merge-from=<tiles>` merges far chunks' buildings from that distance instead of about four
chunks (far_chunks.gd), for screenshots of merged buildings up close.
Each frame also records the sliced systems' books (`fb`: each one's µs used, granted and work
waiting, frame_budget.gd), the chunks wanted round the focus but not drawn yet (`q_undrawn`, and
`q_near_undrawn` within two chunks), and at the end the time from a chunk being wanted to its
buildings being drawn. `python tools/moving_summary.py run.json ... --systems` summarises runs: the
whole frame, the main thread's own work (the frame less the draw's wait for the GPU) and the GPU,
p50 / p99 / worst, the speed walked, the sliced work and chunk latency, and per system how often it
used its whole slice.

The main thread's sliced work (messages, chunk builds, terrain, models, unloading, shadows, the
pick index, clutter, far belt icons, wires, far merging) shares one allowance a frame
(frame_budget.gd): what is left under 16.7 ms (or the FPS cap) after the frame's other work, 3-6 ms,
handed out by priority, with a floor for the near work. `-- --frame-budget=separate` gives every
system its own slice as before, for comparing.
`-- --st-slice=on|off` (on): a machine states message (`st`) of more than 64 states waits in world.gd and is applied
over the next frames within the frame budget's `states` slice (2 ms, 0.3 ms floor; the whole slice when more than
one waits), in the order the messages came, so a unit ends with the latest state sent; the lamps' colours and Always
on in it apply at once. A small one with nothing waiting applies at once. Off: every `st` applied whole as it is
handled, as before (a busy base's 1,600 states took 10-25 ms, a dropped frame each time).
`-- --ih-apply=quick|old` (quick): an inserter hand update (`ih`) binds an arm to its record again only when the
record, its direction, position or pack, or the models in use changed; a new arm looks for a belt at its pickup
only among what stands within a tile (a busy chunk's every record was looked up, 0.3 ms an arm); its place in the
preplan queue is a flag. Old: as before. What is drawn is the same either way.
Belts are the last thing culled (the owner: "id like the belt logic to be high priority on what gets culled for
performance it is integral to the games feel"); each of these has its switch, the old way back when off:
- `--priority-queue=on|off` (on): movement commands (`walk`, `drive`, `enter`) send directly on input events and
  outbox priority packets go ahead of bulk requests (on native UDP directly over `_send_mutex`); incoming `me`
  (priority 1), player interaction replies (`gui`, `slots`, `inv`, `qb`, `cq`, `mnd`, `pku`, `msg`, `shot`, `guns`,
  `bp_ok`, `clip`, `eq`, `hist`, `craftable`, `cmdr`, plus `add`/`upd`/`del` for chunks without a pending snapshot
  in `_waiting`, priority 2), and `bs` (priority 3) drain ahead of the bulk message queue (`_waiting`).
  Pairs with `/f3d-perf prio_queue` (on) in the mod: reliable interaction replies flush ahead of bulk chunk
  snapshots (`outbox_prio` vs `outbox`) with sequence numbers stamped at flush time, and `me` sends immediately on
  the tick movement/driving starts, stops, or turns. Off puts both ends back on the single FIFO queues and 2-tick
  `me` cadence.
- `--coalesce-updates=off`: disables live fast-lane routing (`_live_waiting`: `ie` when `_chunk_waiting` is empty, plus
  `mv`, `rb`, `pj`, `afx`, `hp`) and snapshot coalescing for unreliable single-part snapshots (`cq`, `al`, `sky`) and
  complete multi-part snapshots (`mv`, `ih`, `gi`, `en`, `hp`) ahead of barriers (`welcome`, `ready`, `surface`); reliable
  `r`-numbered `upd`/`st` entries are never coalesced. Off: routes those messages into bulk `_waiting` and skips
  coalescing, as before.
- `--nack=off`: disables sending `{"t": "nack", "r": [...]}` requests (1–64 missing `r` sequence numbers) when the reliable
  stream jumps ahead after `world_ready` (with a 250 ms timeout fallback to `resync` with the incomplete chunk list `c`,
  and a 2500 ms late-retransmit drop guard); falls back directly to `resync`, as before (pair with `/f3d-perf nack_ring`
  on the mod side).
- `--reliable-reorder=off`: reliable messages that arrive after a NACKed gap are handled at once, before the
  retransmits that fill it, as before (a `chunk` header retransmitted after its `ents` then emptied the chunk; a late
  `add` after its `del` left a phantom). On (default, with the priority queue): they wait, keyed by `r`, until the gap
  fills and then go in order; at most 4096 held for at most 1 s, and on the NACK timeout (250 ms) what was held goes on
  in order, a resync is asked for and late retransmits are dropped. Wire unchanged.
- `--prio-delta-order=off`: a chunk's `add`/`upd`/`del` may take the priority lane while an older delta for the same
  chunk still waits in the bulk queue (a `del` handled before its `add`), as before. On (default): deltas queued in
  bulk count for their chunk as `chunk`/`ents` do, so later ones for it wait behind them.
- `--fast-edit-rebuild=off`: disables live-edit rebuild priority (`_dirty_live` preemption ahead of background `_dirty`
  streaming chunks, synchronous chunk mesh prep for `<512` live instances instead of worker tasks, and `>128` near-first
  `_st_lists` application within 2 chunks of `stream_center()`), queuing live edits and states in standard order instead,
  as before.
- `--belt-messages-first=on|off` (on): the belt simulation's updates (`bs`) are handed to the belt layer as they are
  read, before every other message waiting and outside the messages' slice (a few µs each: belt_items.gd queues them
  for its job). Behind a `welcome` or `surface` still waiting (both start the belts over), and behind belt messages
  already queued after one, they keep their place. Off: in the one queue with the chunks, decoratives and the rest,
  so a backlog (a hitch, a burst of chunks) left the belts drawn from updates seconds old. The inserters' events
  (`ie`) stay in order: routed first too, an inserter built during a backlog got its events before its `add` and
  was drawn at the map's origin for half a second, then a tile or two off for its first swings. A belt built during
  a backlog can show its items a moment before the belt itself.
- `--frame-budget-belts=first|off` (first): the far belt icons' slice (belt_lanes.gd, `lanes`) ranks with the
  messages and has a 0.5 ms floor, so under a tight frame the near chunks' builds, terrain, models, shadows,
  levels of detail, decoratives, wires and far merging wait before it; off: priority 6 with no floor, as before.
- `--governor-belts-last=on|off` (on): Hold the game at 60 UPS cuts the belt item distance (`far` 96, 64, 32) only
  after every other step, the view distance and the FPS cap included; off: STEPS' order, `far` 96 at the seventh
  step, as before.
- `--night-vision-fx=off`: no night vision feedback: no sound as it turns on or off (the equipment's own
  activate / deactivate sound, read from the prototype in the player's Factorio install), no icon over the
  shortcut bar and no green edge on the screen. Without it Settings > Interface > Night vision indicator and
  Night vision screen edge (`interface/night_vision_indicator`, `interface/night_vision_edge`, both on) turn the
  two visuals off one by one; the sound follows the Game effects volume.
- `--perf-warning=off`: starts with the performance warning hidden (until Settings > Interface > Performance
  warnings, saved as `interface/perf_warning`, on by default, or the debug menu's row of the same name is changed).
  Both switches show it off meanwhile, without saving that, so one click turns it on.
  It is Factorio's warning triangle at the top left, right of the Show in Factorio button (in its place while that is
  hidden): shown while Hold the game at 60 UPS holds settings back, with how many, and 10 s after the last comes back;
  hover lists them, a click opens the log (perf_log.gd: 200 entries, cleared with each game, the PC's time of day,
  from -> to and why, Copy). The work budget's cut under 300, Automatic moving belt items under half its start (6,000)
  and the bridge's own belt square cut are logged too, without lighting the icon. Off, the log still fills.
- `/f3d-perf belts_last` (on): the far belt lanes' rounds slow only at rate level 3, as the belt simulation's
  updates (which `period_max` 6 never stretches); off: 2, 4 and 8 times apart at levels 1-3, as before.
- `--resync-guard=on|off` (on): a slow join can't loop. `off`: as before. Why: on a slow PC (the second PC,
  GTX 1070 and 4 cores: a first frame of 17.9 s, then frames of seconds) the join never drew anything: the
  character in black, 7,000-9,000 messages waiting, a full `resync` every ~3 s. Two causes, both in bridge.gd.
  (1) The handshake's stall check asked for a full resync whenever `ready` had not been *handled* 3 s after
  the last reliable message was *read*; a full resync starts the bridge's handshake over (world cleared,
  `lod.reset`), and the bridge then sends nothing reliable until the client subscribes, which it does only
  once `ready` is handled, so a client more than 3 s behind asked again for good. (2) Godot caps
  `_process`'s delta at about 0.13 s, and the hello timer added up delta: on frames of seconds a hello went
  every ~8 frames, the bridge (600 ticks without one) dropped the client and started the handshake over at
  the next. With the guard: `ready` read and waiting in the queue counts; a full resync isn't asked again
  while the last one's welcome waits in the queue, and repeated ones back off (2.5, 5, 10, 20, 30 s); the
  messages read before a new session's welcome are dropped, not handled; while `ready` waits the messages
  get the catch-up slice; hellos go by the clock, say `w` 1 once the welcome is read, and the I/O thread
  says the last one again when a frame takes over 2 s. Measured headless against a scratch server on
  Zenith Test with a scratch add-on sleeping each frame until `ready` (`art-src/alt/runs/drain-starve2`):
  3.5 s frames, `off` 5 handshakes, 4 full resyncs, no chunk drawn in 90 s; on, 1 handshake, 0 resyncs,
  all 121 chunks at 19-23 s (2 runs); one 18 s frame then 1.5 s frames, `off` 2 handshakes, all chunks at
  39 s; on, 1 handshake (9 hellos from the I/O thread), all chunks at 31-41 s (2 runs: the same within
  noise, without the restart). Normal speed: as before (121 at 9 s).
- `--message-catchup=on|off` (on): while the oldest message waiting in the bridge's queue (bridge.gd
  `_drain`) has waited longer than `--message-catchup-msec=N` (250) since its datagram was read, the
  messages get their own slice (4 ms) whatever the pool has left. `off`: as before. Why: with the pool
  at its 3 ms floor (the frame's other scripts at 9 ms or more: loading or walking a big base) the
  messages got 2 ms a frame, backlog or not (the doubled slice past 300 waiting is capped by the pool
  too), about 3.2 ms used with the last message's overrun. Since the merge of main's 0.2.0 work
  (68f61e5f; not narrowed further) a frame at -62,-26 draws 11 M primitives instead of 5-6 M and waits
  on the GPU (19-20 ms, 12-15 before): the warm-up runs at ~41 fps instead of 48-54, so those 2 ms a
  frame came to ~138 ms of messages a second, under what the bridge sends there while the client loads
  and stands. The queue grew through the whole 85 s warm-up and drained only well into the walk (the
  recorder slows the game to 25-29 UPS), and every chunk asked for meanwhile was answered behind it.
  The join runs on 68f61e5f (load-hitches' base) already had 1,650-2,800 waiting; the inserter events
  with the samples (`ie` and `ih` both, the hand-off's default) and the datagrams no longer lost took
  it to 4,300-4,700. Measured live (tools/belt_walk_check.py, route fast at -62,-26, Hold 60 UPS; the
  probe's new `STUTTER messages waiting` line and per-frame `q_messages_ms`), off (5 runs) -> on (3):
  messages waiting in the warm-up p50 3,000-3,300 / most 4,300-4,700 -> 35-44 / 171-419, the oldest
  15.6 s behind at p50 (27 s most) -> 0.22-0.26 s (0.8-2.1 s most); chunks wanted to drawn while walking
  p50 31-144 s -> 1.5-2.2 s, never drawn 107-164 -> 0-13; belts visible while walking 54-76% -> 99.0-99.2%,
  phantoms on the recorded lanes 0.8-1.0% -> 0.8-0.9% (the report's total counts lanes past the recorded
  area too, 13-16% when the walk goes further than the recording planned for). Standing (belt_view_check,
  `--record 60`, 2 runs each) unchanged: -62,-26 96.8-96.9% / 1.0-1.1% (before 96.8% / 1.2-1.4%), -272,-14
  98.0% / 0.4% (97.6% / 0.4%), 0 datagrams lost. Cost: the warm-up's frame p50 20.4-21.1 -> 21.9-22.3 ms
  (messages 135-141 -> 167-178 ms a second; the slice raised in 1,730-2,270 frames of ~7,200), frames
  over 33 ms in it 176-222 -> 225-265; walking, p50 19.2-20.5 -> 20.1-21.6 ms and frames over 33 ms 82-103
  -> 147-176, which is the walk's chunk streaming now happening (700-920 chunks drawn instead of 190-260;
  world.gd's own time in those frames 0.47 -> 1.1-1.6 s), the raised slice in only 30-44 of them. The p99
  of chunks wanted to drawn (100-120 s, on and off) is chunks wanted since the warm-up at rings 6-10 of the
  square and drawn once the walk reaches them; the 11-12 builds had none of those. `--frame-budget=separate`
  drains the queue too (most 373-410) but costs every frame (warm-up 34 fps, frames over 33 ms walking
  262-318); dropping the inserter events (`--inserter-handoff=off`) only shortened it (most 3,100-3,500,
  chunks p50 26-45 s).
The probe's frames also record chunk streaming's queues: `q_unasked` (chunks wanted round the
focus but not asked for yet), `q_partial` (builds stopped part-way), `q_shadow` (chunks whose
shadow settings are still to be set) and `q_free`, `q_free_records` (unloaded chunks still to go).

Hitches while joining (the first 90 s), each behind a switch defaulting to what measured better:
- `--lods-finish-usec=N` (2000): models' levels of detail finished on worker threads are shown
  (the stand-in's surface made, the model's levels made as meshes of their own) for at most N µs a
  frame, at least one a frame; 0 shows every finished one at once, as before (a second-long frame
  on the owner's save, several big models at once, while other processes loaded the PC; on a quiet
  PC no frame's finishes took over 5 ms either way, and the joins with 2000 were as good or better).
- `--belt-capture-thread=on`: `--belt-capture` writes each `bs` message on a thread of its own, which
  takes JSON.stringify of a first load's 28 KB updates (2-3 ms each, 5.5 s over a join) off the main
  thread; off (the default) writes them inline. On this 4-core PC the thread made the join worse:
  50-59 frames over 33 ms, the worst belt job 1.3-2.2 s and the first load done at 69-89 s, against
  30-37, 0.77-0.88 s and 53-57 s inline (joins at -62,-26: three with the thread, two inline, and a
  third inline one with --gpu-profile agrees).
- belt_view_check's `--godot-arg=--gpu-profile` is for the render steps' times, not for counting
  hitches: Godot prints its GPU profile every second and those frames stall 400-750 ms (84 in a
  110 s join at -62,-26, shown as `present`).
- The simulation's event queue (lane reads, checks, holds queued for later ticks) is kept by tick
  (belt_sim.gd and BeltSimNative `_apply_queue`): only the due ticks are taken, where every queued
  event used to be scanned and moved each tick. Same order as before (by seq), so no switch:
  belt_sim_native_test shows 0 differences. The probe's `sim_queue_usec` counts applying the queued
  reads as well, which is most of it: 25.3 s over a 90 s join at -62,-26 before, 23.2-23.8 s after.
- `--screenshot` frames are marked in the probe's frames (`shot`): the read-back and PNG encode stall
  that frame about half a second, so `join_hitches.py` leaves them out (`--keep-shots` keeps them).
- The once-a-join frames of 100-180 ms the first 3 s of a join at -62,-26 had left (feature/load-hitches;
  the probe names each part: `w_mv_*` movers, `w_dc_*` decoratives, `w_ic_*` item kinds, `w_rb_*` robot
  batches, `w_ta_*` terrain applies, `w_gs_*` settings applied; `join_hitches.py` attributes them):
  - `--governor-apply=held` (the default; `all` as before): a UPS governor step applies only the knobs it
    holds (view radius, belt distances and cap, entity radius, map refresh, update rate, fps). It used to
    apply every setting again (`_apply_game_settings`: the look, environment, shadows, SSAO, clouds,
    contact shading over every chunk, the models' quality), which on a join was a 2.5 s frame when the
    governor stepped down at 36 s, and after each step a frame of 60-300 ms in the renderer with 70-160
    pipelines compiled again and the shadow atlas (51 MB) made again. Before: 805 pipelines compiled in
    the join's 90 s, 186 of them at draw time; after: 108-130, 20-28 at draw time.
  - `--movers-dress-usec=N` (1500; 0 = all at once, as before): movers whose model has just come
    (robots, rolling stock) are dressed for at most N µs a frame, at least one a frame. Their frame was
    150-180 ms; most of it is the first robot's batch (the robot shader's first use, see the warm-up),
    the rest the hundreds after it, now spread.
  - `--decor-texture-thread=on` (the default; off as before): a decorative's atlas goes on the GPU on the
    worker thread that read its pictures, not when a chunk's clutter is put in. What remained of the
    115-140 ms clutter frame was the kinds' materials' first use of the decorative shaders (the
    warm-up). The texture travels on the KindData with the atlas, so main's race fix (each drawing made
    once per KindData and kept on it, decor_test) holds with it on or off.
  - `--decor-parallel-load=off`: holds `_kind_mutex` across decorative picture loading (one worker at a
    time, blocking main-thread `index()` swaps) instead of per-decorative locks and lock-free `index()`
    preparation.
  - `--terrain-upload-thread=on` (the default; off as before): the terrain Texture2DArray (every layer
    again whenever new ground arrives, 20-40 layers of 1.4 MB) is made on a worker thread; a tile stays
    unknown until the array with its layer is in use. The 90-100 ms `terrain polled` frame is gone; the
    first textured chunk's surfaces (`w_ta_surfaces`) then took 89 ms once instead (the terrain shader's
    first use with that layout; the warm-up takes that away too). Since the merge with main's 0.2.1 hotfix
    (`--terrain-layers`, below) the array has room: a new kind of ground is written into its own layer on
    the main thread (`update_layer`, 2-3 ms) and its tile is known at once; only a new array (the first, or
    one grown when the room is full, or every time with `--terrain-layers=rebuild`) is made on the worker,
    its tiles unknown until it is in use. Off: that new array is made on the main thread.
  - `--item-dress-usec=N` (0, off): item kinds whose model or icon has come dressed for at most N µs a
    frame. Tried at 1500 for the 60-95 ms frame the first kinds made: no gain (a kind's dress was the
    frame: its shader's first use), and belt_items.gd writes every item again each time a kind is
    dressed, so trickling them made the belts' first load take 72 s instead of 22-23.
  - `--warm-shaders=loaded|all|off` (loaded): shader_warmup.gd uses the world's shaders once while the
    client starts (1.7 s before the menu or the connection): each on a tiny box and a one-instance
    MultiMesh for four frames, the ground's layout with the terrain and water materials. A shader's
    variants compile on worker threads from when it is loaded, and the first material using it waits
    for them (on this 4-core PC, with the server, the belt worker and the join's own jobs on those
    threads, that wait was the 53 ms of the first item kind, the 120 ms of the first robot, the 100-115
    ms of the first chunk's clutter, the 59 ms of the character, the 89 ms of the first textured
    ground). Warmed, every one of those is under 3 ms; the join had 88-107 frames over 33 ms, 4-9 over
    100 ms, none of the named ones left (two runs; against 102-132, 8-13 and the named ones at 130-310 ms
    without; the frames left are the renderer's own, belt_items.gd's, chunk builds). `loaded` takes the shaders the
    scripts have loaded (all 35 spatial ones here, as the world's scripts preload them), `all` every
    spatial shader in res://shaders. The first run with the warm-up on had the worker threads busy for
    half a minute into the join (the models, clutter and terrain came 29 s late, the belts' first load
    took 80 s): its new pipelines (every shader on a MultiMesh) compiled in the background and went into
    Godot's pipeline cache; the runs after found them there. Not settled whether that was the cache's
    first fill or another process on the PC. With main's `--pipeline-warm` (pipeline_warm.gd, below) both
    run and don't overlap: this warm-up is the shaders' own compile, once while the client starts, on a
    box's vertex layout and the ground's; pipeline_warm.gd warms each model's own (shader, vertex layout)
    pipelines far under the world as the model arrives, and its keys are those layouts, so the two don't
    compile the same pipelines and neither holds the other's instances. The join's "Preparing models and shaders"
    screen (`--join-warm`) waits only on pipeline_warm.gd's.
  - Still there, measured and named: the renderer's own frames in the first 15 s (40-160 ms, no
    pipelines compiled; the probe can't see into the renderer), `MultiMesh.mesh =` on a kind with
    instances (7-27 ms, `w_ic_d_mesh`), the first chunk's MultiMeshes (50 ms, `c_us_build_apply`), a
    model's levels of detail finished in one go (up to 50-107 ms, `w_lods`), message handling (`before`,
    30-70 ms: the `welcome`, `ih`, `mv` and `bs` messages over 8 ms each are listed in the probe's
    STUTTER lines). The belts' first load (`bs ld` done) varied from 22 to 89 s between runs of one and
    the same setting here (the belt worker's jobs fewer and longer in the slow ones), so a first-load
    time from one run says little; the belts' live visible and phantoms were 96.1-96.2% and 2.3-2.6% in
    every run, before and after.

Items on belts are run by the client's own copy of Factorio's belt rules (client/scripts/world/belt_sim.gd,
docs/BELT-SIM-PLAN.md; the bridge sends `bs`). A bridge mod from before `bs` (0.1.4 or older, say a copy
left in Factorio's own mods folder for hybrid games, or another player's server) still sends `bi`, which this
client no longer draws: the belts near you stand empty, and the client says so once in its message line
("The bridge mod ... is older than this Zenith"); update the mod. Its replay test checks it against a recording of the game
(`python tools/belt_sim/record.py`): `godot --headless --path client -s res://tests/belt_sim_replay.gd --
[rec.json] [--bench] [--tile=N]` starts from the recording's first tick, steps on by itself given only what
the game put on and took off, and counts the items that aren't where the game has them (the default
fixture must have none); `tools/belt_sim/sim.py rec.json --mode free` is the reference it agrees with.
`-s res://tests/belt_sim_bench.gd -- --items=80000` times it on a synthetic world.

How the simulation's items are drawn has toggles, all on by default, so the drawing as it was can be
compared (the client reads them at start-up, `-- --belt-sim-ahead=0` and so on; `tests/belt_bs_replay.gd`
takes the same):
- `--belt-sim-ahead=N` (`auto`; was 24, and 1 before `--belt-draw-early`): the simulation runs N ticks past the drawn
  tick, what it says happens after that tick waiting for the next job. 0: stepped to the drawn tick, so items a
  read moved or put on a lane on that tick are drawn from their old records until the next job. `auto` (the
  default): at least 24, and at least the last job gap and 6 ticks (E46: a 24-tick lead under a 30-tick job gap
  left the stops and starts of the gap's last ticks to a job late, drawn a job's travel off); never past the
  newest update, as before, so it needs the drawn clock far enough behind the game (`--belt-draw-lead-lag`).
  `--belt-sim-ahead=24` is the lead as before.
- `--belt-draw-gone-order=off`: a job applies every change, then removes every item gone in its ticks (an
  item dropped and put back in one job stays undrawn till its next change); on, both in the
  simulation's order (`take_changes()`'s `gone_tick`, `gone_at`).
- `--belt-draw-lead=off`: a record that ends is made again only once it has ended (the item stands at
  its end till the next job), and an item past its lane's back end is hidden until its record ends; on,
  made again a little before, by a path across where it ends that shows it exactly where it comes onto
  a lane or out of the ground.
- `--belt-draw-head-move=off`: the simulation's changes say the step a head item was given (items
  waiting at a splitter or side-load were drawn moving on) and items leaving a line aren't emitted. Both
  belt_sim.gd and BeltSimNative honour it (`head_move`); the rules don't change.
- `--belt-sim-read-apply=off`: reads applied as before this round. On (the default): a lane's meta
  (`lm`) takes effect at the tick of its first read in the update (`set_lane_at`), not when the message
  comes, so the line behind a lane loaded in that update doesn't run on into it, empty, until its read;
  a read never leaves an item past its line's back end:
  what its packed run, the items it pushes back out of its lane and those it spaces out leave there is
  carried back onto the feeder's line (a splitter output's: the input on that side with more room, the
  side's turns put back), its items behind going back a gap as needed, up to 8 lines (`_carry_back`;
  where it can't, they go); and a read of a splitter's output with an item the simulation sent into the
  side's other output (or on along it) sets that side's output turn too. Both belt_sim.gd and
  BeltSimNative honour it (`read_bound`).
- `--belt-sim-read-conserve=off`: reads drop what they don't have as before. On (the default): a read
  takes off only the items its lane had between the read's own (taken); those behind the read's items
  in the line's order (all, when none of them is in the line) go out of the lane behind it, those ahead
  out of it in front, in order (`_rescue`); what that leaves past a back end is carried back up to 32
  lines, never onto a splitter input nothing feeds. Both alike (`read_conserve`).
- `--belt-sim-read-forward=off`: the items a read leaves past its line's front (the read lane is the line's
  first: a splitter's input, a lane whose next is another line, and the read hasn't them) go, as before. On
  (the default): they are carried on into the line they went on into in the game: across a splitter into
  the output its turn (or priority, or filter) says where there is room, else the other, the side's turns
  moving on as for a crossing; into a plain next lane behind its hindmost item (`_carry_forward`). Where
  the lane leads out of what is sent, or nothing has room, they go, as before. Against the every-tick
  recording at -62,-26 such drops were 47% of the items reads took off that the game still had (an `sh`
  hold keeps a splitter input's items while the game crosses them; the read then finds them ahead of its
  own), and a hole in a packed bus stays until the lane is read again. Replayed on that capture (every tick,
  by place within 0.15 tile on recorded lanes): 88.6% -> 91.3%, phantoms 3.3% -> 3.2%, items lost while the
  game still had them 4,042 -> 2,913 in 600 ticks. Both alike (`read_forward`).
- `--belt-sim-shift-keep=off`: a read's packed-run shift goes on past an item outside the lane that the
  shift would bring into it where the read hasn't it, and that item goes, as before. On (the default): the
  run's shift ends at that item, which stays where the simulation had it (`_shift_packed`): against the
  every-tick recording at -62,-26, 81% of such items were still on the belts, ahead of or behind the lane
  (814 of the 4,042 items reads took off in 600 ticks that the game still had). Replayed with read_forward:
  91.3% -> 92.3% by place, but phantoms 3.2% -> 3.9% (kept items the game has elsewhere). Both alike
  (`shift_keep`).
- `--belt-sim-read-skip-same=off`: a read (`sl`) that finds the lane exactly as the simulation has it (every
  item at its place, none else) is applied all the same, as before: the line rebuilt and every item's record
  written again. On (the default): it is skipped, its items only noted fresh for the tick (`read_skip_same`,
  both twins alike). Offline on the lattice run's capture at -62,-26, 51% of the bridge's reads were such, and
  applying reads was 80% of the simulation's time (2.7 of 3.4 ms a tick; stepping 0.7).
- `--belt-sim-take-first=off`: an inserter's take (`ie`, `--inserter-handoff`) and the bridge's read of its lane
  are applied in the order they came, as before. The bridge sends `bs` before `ie` in a tick, and the mod sees a
  pick at its check, up to a tick or two after the hand closed, so the read of the pickup lane on the take's tick
  often came first: it found the taken item missing behind its own items (or the lane empty) and pushed it back
  out of the lane as one the simulation had run on into it (`_rescue`): the taken item stood again at the start
  of the belt, the items behind it pushed back with it, and the take then found the lane read and did nothing
  (owner, K9). On (the default): a read first makes the takes queued for its belt up to 3 ticks on, of the items
  it hasn't on its lane (each take's own choice, nearest its hand), gone on the take's tick; a take that comes
  after a read as of its tick takes the item that read moved instead (the items behind it stay where the read
  put them then). The character's F pickups off belts go the same way (takes with no inserter). Both alike
  (`take_first`; belt_sim_native_test.gd's `take before read` pass, the UI test's `_belt_take`).
- `--belt-sim-take-line=off`: as before, what the bridge sent was applied in the order it came, tick by tick,
  and a take took the item nearest the hand. The bridge sends an update's lane reads before the tick's hand
  events, so on a take's own tick the reads came first; the read of the lane behind the pickup lane found its
  items a step on (the line closing the hole) and moved the packed run in front with them, the taken item too,
  across the belt's edge; the take then found its belt read and the item no longer on it, and did nothing. The
  item stayed, the line behind it a gap out, and every later read of that line moved long runs a whole gap one
  way or the other (a quarter tile, dozens of items at once, a line's front items past its end) until they
  agreed again (owner, K19: "belt items all of a sudden jump around", an inserter taking from a line backed
  up to its end). On (the default): what is queued is applied by tick, a tick's takes before its reads; and a
  take takes the item its belt's next read hasn't when that read has come already (the bridge reads a hand's
  belt when it sees the hand changed), the nearest the hand otherwise: a pick stamped two or three ticks after
  the hand closed carries the hand's place that far into its swing, nearer the neighbour. Both alike
  (`take_line`; belt_sim_native_test.gd's `take at a line's end` pass, the UI test's `_belt_line_end`).
  `tools/belt_line_end.py` makes the scene (a line that ends, backed up, inserters taking from it) and plays
  the bridge offline; `tests/belt_bs_replay.gd --every-tick --ie-wire=0 --sim-dump= --belt-draw-dump=` replays
  it with the hands' events reaching the job as on the wire (the capture's own order hands them over an
  update early, which hid the fault), and `tools/belt_jumps.py` counts what jumps: the simulation's items
  against the game's, and what is drawn tick by tick (things appearing or vanishing off their motion, game
  items unseen, phantoms). Its `--hands-radius R` sets the bridge's f3d-detail-radius so only the inserters within
  R tiles of the focus send `ie` (live: those past the hands radius send none), the rest seen only in the bridge's
  lane reads: `--belts 40 --queue 36 --take 25 --feed 6 --ticks 2400 --hands-radius 4`, replayed with
  `--view=-4,4,52,13` and scored by `tools/belt_quirks.py --every 30`, draws stop-and-go lanes standing (E46).
- `--belt-sim-take-edge=off`: a take looks for its item on its belt's own lanes only, as before. A take made
  late (the hand's `ie` pick comes a few ticks after the hand closed) at a belt's front edge found nothing:
  the simulation had run the item on over the edge onto the next belt. The read of that belt's lane, without
  it, then put it back at the lane's entry (read_conserve: the game's hasn't arrived yet), where it stood in
  for nothing and joined the queue's tail. On the line-end scene (`tools/belt_line_end.py`, seed 1) item 168,
  taken at tick 102455, lived on for 372 ticks and left the items behind it a gap off. On (the default): the
  take looks that far past its belt's front edge too, on the line running on from it, as far as the lanes ran
  since the take's tick (and TAKE_LEAD's three ticks of slack), and among what a read of the lane ahead
  moved back to its entry when the reads came an update before the pick. On that scene, both twins alike: item 168 gone
  on its tick, simulated items the game hasn't 328 -> 80 (item-updates), drawn phantoms 0.12% -> 0.04%
  (`tools/belt_jumps.py`; things appearing or vanishing off their motion 282 -> 266), `tools/belt_quirks.py`
  phantoms 10 -> 3 item-s and jumps 3 -> 0. `take_edge`; belt_sim_native_test.gd's `take at a belt's front
  edge` pass.
- `--belt-sim-rescue-seen=off`: a read put every simulated item it hasn't, behind its own items (or all of them
  when it has none), back out of its lane behind it as one the game's has yet to reach, as before. Past the
  bridge's hands radius no `ie` comes, so an item an inserter took was put back by each read without it and lived
  on as a phantom (the line-end scene with `--hands-radius 4`: item 305, taken over b36, pushed back by four empty
  reads of b36 and b35, joined the queue's tail for good). On (the default): an item isn't put back into a lane read
  as of that read's tick or later without it (the whole update's reads count, a pickup belt's and its feeder's
  either way round), nor further back than a gap behind where the bridge last read it, nor a third time with no
  read listing it in between (RESCUE_STRIKES); it goes. A take that comes late still finds it (`_take_rescued`).
  On that scene, off / on (and `--belt-sim-read-conserve=off` for comparison): `tools/belt_quirks.py --every 30`
  phantoms 7.93 / 1.86% (1.77%), missing 0.69 / 0.75% (0.77%), jumps 403 / 57 (36); simulated items the game
  hasn't 1206 / 166 item-updates (158). The control without `--hands-radius` is unchanged (0.72%, 0.50%, 36).
  `rescue_seen`; belt_sim_native_test.gd's `rescue seen` pass and a synthetic world with it off. Not behind the
  switch (a fix either way, both twins): a read listing one unique id twice keeps the first only, and a late take
  takes a rescued item only if it is still on a line (`_take_rescued`'s `_uid_line` guard); before, such an item
  could be taken and handed out twice. So `=off` is the old rescue, not the old code exactly.
- `--belt-sim-ug-guard=off`: an underground's hidden tunnel lane the bridge sends no next for (`lm` next 0: an
  entrance with no exit) links by geometry like a belt, as before: with no entrance at its end it side-loaded onto
  the straight belt beside its exit. On s272_out an express underground's tunnel (lane 35360348) fed a turbo belt
  half a tile west: items the game held at the entrance ran 14 tiles down that belt and stood at its end as
  phantoms, taken back by each read of the entrance and let go again. On (the default): a tunnel's geometric next
  is only another underground's visible half, a tunnel never side-loads, and an entrance whose tunnel leads
  nowhere ends at its own end (the game's items stand there). Zoomed out at -272,-14 (owner's settings) phantoms
  1.38% -> 0.76% of the game's items in view (on the item lanes 12,895 -> 6,575 item-s), missing 0.28% -> 0.26%,
  counted jumps 525 -> 421 a second. Both alike (`ug_guard`; belt_sim_native_test.gd's `underground tunnel with
  no next` pass).
  A tunnel the bridge names an exit for (`lm` next the exit's line, or minus it when the exit is outside what is
  sent) leads on whether its exit is loaded or not: its items go into the tunnel and stand at its end or leave by
  the out edge, as the game's do. (Till fix/ug-guard-edge it led on only with the exit loaded: an entrance whose
  exit was outside the square was a dead end, its items held at the entrance; belt_sim_replay.gd on the default
  fixture 0.879% off on `underground hidden`.) The dead end is for next 0 alone (an underground with no exit),
  and only where the lanes' next says so (`next_named`, on): belt_sim_replay.gd's recordings carry no `lm` next
  (a tunnel's 0 there says nothing), so it runs with `next_named` off, 0.000%. Zoomed out at -272,-14 (owner's
  settings) phantoms 1.32% off -> 0.72% on, missing 0.25% -> 0.23%, jumps 475 -> 375 a second. Both alike
  (belt_sim_native_test.gd's `underground's named exit`: exit later, exit outside, exit not loaded, next unknown).
- `--belt-sim-hold=off`: the bridge's `sh` ignored. On (the default): a splitter's input the bridge found as
  its last read left it is put back so and held (its items don't cross into the outputs) until its next
  read (`hold_input`). Both alike (`hold_inputs`).
- `--belt-sim-split-wake=off`: splitters let an item through whenever the belt rules say. On (the default):
  a splitter side that let an item through one or two ticks ago (three, while its other output moves) takes
  its turn before the belts that start moving this tick, as the game's update order does: an output that
  stood last tick and has room only once its items moved on this tick takes nothing from it that tick
  (docs/BELT-RULES.md section 6). Both alike (`split_wake`).
  `--belt-sim-split-wake=old`: the wait rule as it was (a crossing one or two ticks ago, three while the other
  output moves). The default is the R4 rule: that output stood last tick and is full at its back, and either
  the input that crossed last moved last tick and crossed less than 64 + one step of travel ago, or the other
  output moved last tick and moves now with a crossing three ticks ago or less (`split_wake_r4`, both alike;
  belt_sim_replay.gd `--split-wake=old`, tools/belt_sim/sim.py `--wake-rule r0|r4`). Splitters with a priority
  or a filter stay out of it (tools/belt_sim/sim.py `--wake-prio` shows it worse on one recording).
- `--belt-sim-split-hints=off`: the bridge's splitter crossing hints (`bs` `sx`, `/f3d-bs crossings hints`, the
  bridge's default) are not followed: splitters cross by the rules and `--belt-sim-split-wake` alone, as before.
  On (the default): an item a queued hint (at its crossing's tick or later) still has at an input's front waits,
  and a crossing item goes into the output a hint has it on, the side's turns following (`split_hints`, both
  alike). The old way whole is this plus `/f3d-bs crossings sim` on the server (an older client against this
  bridge: `/f3d-bs crossings sim` saves the hints' bytes). Offline (the R&D's recordings at -62,-26, hints every
  6 ticks, nothing else read): 2.24% -> 1.69% of item-ticks off on rec80, 6.85% -> 0.87% on rec80b.
- `--belt-sim-split-reconcile=off`: a read (`sl`) of a splitter's input or output lane is applied as any other.
  On (the default): one that differs from the simulation only by when items crossed (the same splitter's other
  lanes' reads in the same batch, or the hints, have them across) or by a lane's lag (an input's item still on its
  feeder, an output's already on its next lane) isn't applied, so the line behind the splitter isn't torn
  (`split_reconcile`, both alike). Offline with every splitter lane read every 6 ticks besides the hints:
  5.92% -> 2.83% off on rec80, 6.18% -> 4.20% on rec80b (belt_sim_replay.gd `--split-reconcile=off`).
- `--belt-sim-lattice-no-bre=off`: a lane the lattice draws (full of one kind) whose drift check (`pc`) fails
  is asked for again (`bre`) as the ask rules say. On (the default): it is not asked while the lattice draws it
  (a packed balancer's lanes drifted at the splitters, about 900 asks a second) and is asked the moment it
  leaves the lattice (`Job.lat_no_bre`, belt_items.gd).
- `--belt-sim-dead-walls=on` (off by default: as before): a lane that leads nowhere in the simulation (no next by
  geometry, none named, not side-loading, not a splitter's input) though the bridge didn't say it leads out of
  what is sent (`lm` next 0) is walled as such a lane is (`set_wall`) by a read that finds its front item where
  the read before did: the game's front stood there, short of the lane's end, behind an item on a belt that
  isn't sent; any other read of it takes the walls away (its front runs to its end, `EDGE_STOP`, as before). At
  -62,-26 the bridge sent a bus's last belts (165697 .. 165721, lm next 0) without the belt they feed, and
  marked 165737 next -1 though 165729 was sent: the simulation pulled the front up to the lane's end, each read
  put the packed line back a fraction of a gap and the line behind ran on again. Offline (the restart capture,
  `tests/belt_bs_replay.gd --every-tick=60 --job-every=30`, `tools/belt_quirks.py`) items jumping over half a
  tile 193 -> 39 a second, phantoms 1.69 -> 1.14%. Off by default: the bridge's `/f3d-bs lane_next` fixes the
  marks themselves. Both alike (`dead_walls`; belt_sim_walls_test).
- `--belt-early-bs=off`: `bs` parts that come before the world is ready (the bridge's welcome done, the
  prototypes known) are dropped, as before. On (the default): they are held (up to 4,096) and handed to the
  belt layer in order once it is. The bridge loads lanes from the hello on and sends each lane's meta (`lm`)
  once, when it loads it: a dropped part's lanes were read and checked from then on but never placed (two
  of five captures at -62,-26: a turbo underground and curve beside the character empty for the whole run).
- `--belt-sim-ask-unknown=off`: a lane read (`sl`) or checked (`pc`) whose meta never came is left out, as
  before. On (the default): it is asked for again (`bre`, at most every 3 s), which the bridge answers with
  its meta, as docs/PROTOCOL.md's `bre` says. Covers updates lost on the way too (UDP): a capture at
  -272,-14 lost three updates during the first load and with them 187 lanes' meta.
- `--belt-sim-removed-now=off`: a belt Zenith takes away keeps its lanes and items until the bridge's `dl`, as
  before (K22: "breaking a belt with items shows the 3d items in the world for a while": the `dl` came with a later
  update, and a dropped lane's items then stood up to 40 jobs for far icons that never come inside the square). On
  (the default): main.gd tells the belt layer of every belt removed (`mnd` with the entity gone, `del`) and built
  (`add`); the next job takes a removed belt's lanes out of the simulation and its items out of the drawing and the
  lattice, gone at the drawn tick (an item whose motion changes within the simulation's lead goes when the drawn
  clock reaches that change, at most 24 ticks), and passes over the bridge's reads and checks of those lanes still on
  their way (10 s, or until their `dl`). A belt built on its tile before that job (a fast-replace: `add` and `del`
  together) keeps them: the bridge's `bs` hands the items to the new lanes. Both simulations alike, both records
  paths (the UI test's `_belt_removed`).
- `--belt-sim-replace-at=off`: a lane the bridge drops (`dl`) goes the moment its update comes, as before. On (the
  default, with `--belt-sim-read-apply`): one dropped in the update that brings a lane of the same place (exit and
  entry: a belt fast-replaced, yellow by red, say) goes at that lane's read tick, as the simulation gets there, so the
  game's items, which stay on the belt, carry on onto the new lanes. Before, the update came a few ticks ahead of the
  simulation: the replaced belt's items left it then and came back on the new lanes at their read (in the UI test, 4
  frames gone). Both simulations alike (only when `drop_lane` is called changes).
- `--belt-draw-coalesce=off`: every change the simulation emitted in a job's ticks is made into a record,
  one after another, as before. On (the default): only an item's last change at or before the drawn tick
  is; the earlier ones would be overwritten before anything is drawn. Live at -62,-26 a job that had
  fallen 258 ticks behind applied 806,000 changes for 65,000 items (twelve an item) in 8.6 of its 11.4 s.
- `--belt-draw-view=off`: every item gets a record wherever it is, as before. On (the default): an item
  whose motion can't show on screen (its record would lie 4 tiles and its reach outside the camera's
  ground view: the four corner rays met with the items' height, cut 160 tiles out) is parked, its motion
  kept but no slot and no record, until a change or the camera brings it in (the view the records were
  planned for is kept 10 tiles wider than the camera's, so panning a little doesn't plan every parked
  item again). At -62,-26 the camera sees about a tenth of the 160-tile square the client simulates.
- `--belt-draw-view-ground=off`: the camera's ground view for `--belt-draw-view` is cut 160 tiles along
  each corner ray from the camera, as before. On (the default): each ray is followed to the ground however
  far it goes, and the view is cut to the simulated square instead, since no simulated item lies outside
  it. Zoomed out (the camera 140 tiles back at 40 degrees, the owner's screenshot), the cut view ended
  about 31 tiles north of the character while the screen showed 112 tiles. The belts in between are inside
  the square, where lane icons are left out (`far_lanes` or not), so they were drawn empty: the mid-range
  gap. Live at -62,-26 with belt_distance 128, item_models_max 20500 and view_radius 10, the game's items
  on screen within 128 tiles with neither an item nor an icon went from 6.25% (12.4% at 64-96 tiles, 46%
  at 96-128) to 0.09%; `/f3d-perf far_lanes off` didn't fill it (icons 0.0-0.1% inside 96 tiles).
- `--belt-draw-view-lead=on`: the job's view is stretched ahead of the camera's own motion, as far as it goes in
  two jobs' time (48 tiles at most). Off (the default): as before. Walking close up at -62,-26 (camera 12 tiles
  out) the screen's leading edge ran past the records planned for it in two runs of three: 1.65% and 2.37% of the
  game's items on screen had neither an item nor an icon, against 0.02% in the third. With the lead on it was
  0.12% and 0.04%, but a job had 14-22% more records and more counted jumps (32 -> 58 and 30 -> 49 a second; the
  walk check's phantoms 0.7% -> 1.3% and 0.7% -> 0.8%). Left off until the gap is caught again.
- `--belt-lanes-dump=<file>` (a diagnostic): the lane icons as made and dropped, the icon shader's square
  and distance, and the camera's whole ground view every 250 ms (with the frame rate), for
  `tools/belt_quirks.py`'s gaps by distance (items, icons or neither).
- `--belt-draw-dump-parks=off`: the draw dump leaves out a parked item's record going (`--belt-draw-view`: an
  item whose motion can't show is parked and its slot hidden), as before. Its readers (belt_view_check.py's
  DrawState: the live score, belt_quirks.py, belt_jumps.py) kept drawing the record the GPU had hidden,
  standing where its motion ended, and counted the next record a jump. On (the default): a park is dumped as
  the record's going. Both drawing paths alike (belt_draw_diff.py; the twins' going lists equal job by job on
  a replay with a drifting view). Walking close up at -62,-26 the counted jumps went from 38.7 to 32.4 a second.
- `--belt-draw-margin=N` (120): the most ticks the drawn clock is held behind the game's clock for the
  jobs (the margin grows to 1.5 jobs' ticks, from 2). 30 as before: a job longer than 20 ticks (-62,-26's
  take about a second) then ended past the drawn clock and its records were drawn stale, items standing at
  their ends while the game's went on. 120: at most two seconds behind, the records fresh when drawn.
- `--belt-job-high=off`: belt items' job goes to Godot's worker pool as a low-priority task, as before.
  On (the default): a high-priority one. Low-priority tasks get a share of the pool's threads (0.3 of
  them: one on a 4-thread PC), and the belt job queued there behind models' levels of detail,
  decoratives, terrain and far chunks; after main's heavier levels of detail and decoratives came in, a
  job's result came about twice its own time late, each job stepped 80-110 ticks and the drawn clock sat
  at the 120-tick margin. Live, Hold 60 UPS, `--record 60`, by day: -62,-26 off a job cycle of 1.6-1.95 s
  (33-46 jobs a run, margin 120), on 0.33-0.41 s (167-211 jobs, margin 39-56), visible 95.7-95.8% /
  95.8-95.9% and phantoms 2.7% / 2.6-2.7% either way; -272,-14 off 1.6 s (40 jobs), on 0.16 s (383 jobs,
  margin 20), PASS both ways (97.5%, 0.9 / 0.8%).
- `--belt-job=pool`: belt items' jobs go back to Godot's worker pool (`--belt-job-high=off` chooses low priority)
  instead of the dedicated persistent worker thread (`Thread` + `Semaphore`). Default is `thread`, preventing belt
  jobs from queuing behind terrain, LOD, or decorative worker-pool tasks.
- `--belt-draw-dump=<file>`: what each job writes for the GPU, as written: a JSON line per job (its
  cost by part, ticks stepped, the updates it took, changes, records, whether it skipped), then the
  records of the items it wrote (uid, item, count, lane, pos, t0, v, reach as int64; the 16 floats of
  each record as the GPU gets them), the uids gone and the paths' texture when it was made again; the
  main thread writes `<file>.apply.jsonl` with when each job's result was drawn, where the drawn clock
  was then and how late. tools/belt_view_check.py scores it against the game (below). It costs about
  0.1 ms a job plus the write of the items' records (a few ms for an update's job).
- `--native-lod-mesher=off`: Distant Horizon's section meshes (lod_mesher.gd) and the far chunks' merged meshes (far_chunks.gd, Merge) are built in GDScript, as before, even when the C++ library has `LodMesherNative` (the default; same arrays bit for bit, `tests/lod_mesher_native_test.gd`).
- `--belt-draw-native=off`: a job's records are planned and written in GDScript, as before. On (the
  default, when the extension is loaded and the simulation is BeltSimNative): `BeltDrawNative`
  (`client/native/belt_sim/src/belt_draw_native.cpp`) does it, from the simulation's changes to the
  records' pages, item for item as belt_items.gd's Job does, down to the float32 roundings
  (`python tools/belt_draw_diff.py gd.bin native.bin` compares two dumps of the same capture, from
  `tests/belt_bs_replay.gd --belt-draw-dump=<file>` with the switch off and on: 0 differences; add
  `--cap=N` for an Items in 3D cap of N, and `--cam=x,z` for a drifting camera leading it, so both paths'
  camera-led caps are compared too). Live at
  -62,-26 a job took about a second in GDScript, 80% of it planning and writing 60-100k records.
- `--belt-draw-pile=off`: each copy of a pile (a stack on a belt, up to four in one place) gets a full
  record of its own, written again whenever its item moves, as before. On (the default): a pile is one
  record, the item's; each copy's record points at it (texel 3: slots to the item, its step k, the kind's
  pile step) and holds the copy's own turn (texel 2), written once when the copy gets its slot, and the
  shader (belt_path.gdshaderinc) lifts the copy by k. At -62,-26 86% of the items are stacks of four.
  Both paths (GDScript and native) take the switch.
- `--belt-draw-lattice=off`: every lane drawn from the simulation, as before. On (the default): a lane
  the bridge's last read (`sl`) found full of one kind, while its drift checks (`pc`) since say it is still
  full, is drawn as a lattice (`client/scripts/world/belt_lattice.gd`): its item every 0.25 tile, each slot
  cycling within its own gap of the lane at the speed of the simulation's front item on the lane (the
  record's texel 3 holds the period and the shader takes the drawn clock modulo it; a new speed must hold
  two checks in a row), and the simulation's own items on it are hidden by a mask of those lanes' centre
  lines (`f3d_belt_mask`, 4 cells a tile); they stay simulated, and show again as they leave the lane.
  Items sit 0.25 tile apart, so a full lane drawn at any phase has each game item within 0.125 tile of a
  drawn one: the owner's concession, a lane the game has packed is drawn packed. A straight lane's phase
  is the map's (a function of its exit's place and the tick, so a run's lanes agree); curves and splitters
  take the simulation's front item's. `--belt-draw-lattice=sim`: every lane the simulation's phase (the
  first build). The lattice is made in GDScript after either records path, with its own records
  (`f3d_belt_lattice`) and MultiMeshes, so both paths draw it alike (`tools/belt_draw_diff.py`: 0
  differences). (Full: as many items as whole gaps fit in the lane, every gap at most 66/256; lanes under
  the ground, loaders, linked belts and lanes longer than 4 tiles keep the simulation's items.) Live at
  -62,-26 (Hold 60 UPS, `--record 60`, by day): off 87.6% visible, 4.2% phantoms; `sim` 94.5 / 91.9%,
  3.5 / 3.6%; on 95.7 / 95.2%, 2.4 / 2.5% (inside the screenshots' bounds 97.7 / 97.1%). At -272,-14:
  97.0 / 97.1%, 1.3% (PASS). docs/BELT-SIM-PLAN.md, the lattice section.
- `--belt-draw-lattice-pile=off`: every lattice slot one item, whatever the lane's stacks (the lattice's
  first build: a bus of stacks of four drawn flat, owner: "nothing shows as stacked items any more"). On
  (the default): a lattice lane's slots are piles as high as the stacks its last read (`sl`) found most
  often, each slot its record and a copy per step above it pointing at the slot's record as the items'
  piles do (texel 3: the slot from the copy, its step k, the kind's pile step; each copy turned PILE_TURN
  more than the one under it, cards and blocks too). The shader reads the slot's texel 3 for a copy, so
  copies slide with their slot and aren't hidden by the lattice's mask.
- `--belt-draw-lattice-unison=off`: the lattice as first built: a slice of the drawn lanes has its speed
  checked against the simulation's each job, and a lane takes a new speed only at two checks in a row.
  So when a backed-up run started moving its lanes changed speed jobs apart, and at each lane boundary the
  sliding lane's slots opened and closed a gap of up to 0.25 tile against the standing neighbour (the
  owner's "shimmer of small gaps"), while at the run's ends the simulation's own items moved away from the
  standing lattice for two jobs. On (the default): every drawn lane is checked every job and a new speed
  is taken at once, so a run's lanes change in the same job as the simulation's records; the map's phase
  keeps their lattices in step. `tools/belt_unison_check.py` measures it (an every-tick recording and the
  client's `--belt-draw-dump`): the largest deviation of the drawn spacing from 0.25 tile on lanes the game
  has full, and the share of such lane-ticks showing a gap, overall, in the 30 ticks after a full lane
  starts moving, and on full lanes moving (a loop).
- `--belt-draw-lattice-settle=off`: as before, a standing lattice took its lane's new speed at once. A take
  from a backed-up line moves every item behind it one gap on, and they stand again: a row of one kind a
  whole gap on is the same picture, but each lane's lattice went to the map's phase (up to 0.125 tile from
  where it stood), slid for an update or two, stopped wherever that left it and was set again at the lane's
  next read or check, so the whole line behind the hand jumped an eighth of a tile twice at every take (K19).
  On (the default): a standing lane takes a new speed only once the simulation has had it moving for more
  than two gaps' time (16 ticks on a yellow belt: a line that really flows); its standing phase is the
  simulation's standing front item's (a read made mid-way through the closing gave a phase part of a gap out
  until the next); a lane that comes to be drawn while it moves waits as long (drawn from the simulation
  meanwhile); and the hole a take leaves in a standing lane closes once the drawn clock is a gap's time past
  the take (it stayed open for as long as the lane stood full). belt_lattice.gd and BeltLatticeNative alike
  (`tools/belt_draw_diff.py`: 0 differences). Measured on `tools/belt_line_end.py`'s scene with
  `tools/belt_jumps.py` (3,000 ticks, 81 takes, both K19 switches): things drawn that appeared or vanished off
  their motion 2,253 -> 343, the most in one tick 135 -> 8.
  With per-item turns (`--belt-draw-lattice-turns`) a lane that starts or stops keeps each item's turn;
  through a one-gap closing the lattice stands, so each place keeps its turn.
- `--belt-draw-lattice-creep=on` (off by default: as before, a standing lattice lane moves only when the simulation's front
  item on it moves (and, with settle, only after two gaps' time of steady motion). On a creeping lane (an
  inserter's pickup belt, a merge, a line behind them: its items move up a gap and stand, again and again) the
  front item waits at the exit while the items behind it close up, so the whole lane was drawn standing for
  seconds while the game's items moved on (the owner: "items on belts sometimes hold in place for like 10
  seconds or groups of items")). On: each drawn lane keeps a running share of the time most of
  the simulation's items on it move (`lane_fronts(keys, 1)` in both simulations: the speed most of a lane's
  items move at), over 2 s (CREEP_TAU 120 ticks, in 1/1024: integers, so both twins agree); a standing lane
  whose share passes 25% slides on from where it is drawn at that share of the belt's speed, below 10% it
  slides on to the simulation's standing front's phase and stands there (no jump either way), and once the
  simulation has it moving steadily for four gaps' time the usual rules take the belt's speed. A single
  take's closing (K19's case) stays under the threshold: on `tools/belt_line_end.py`'s scene
  `tools/belt_jumps.py` counts the same 282 things appearing or vanishing off their motion with it on as
  off. belt_lattice.gd and BeltLatticeNative alike (`tools/belt_draw_diff.py`: 0 differences). Off by default:
  live at -62,-26 with 57 pickup inserters stopped over the settle and restarted while recorded
  (`tools/belt_quirks.py`, 30 s at 2 Hz), lanes drawn standing while the game's items moved fell from 23.2%
  of the item-seconds in view to 2.7% (spans of 8 s or more 1721 -> 378, tools' holds count), but the
  simulation moves many lanes the game holds (into splitters, between reads), and those slid: lanes drawn
  sliding while the game's stood 4.2% -> 16.5%, lattice hops 478 -> 1610 a second, visible 97.1 -> 96.4%,
  phantoms 1.7 -> 1.8%. Before it can be on it wants a test that a lane's items really flow through it (its
  front item changing to new ones, or the bridge's reads showing the game's lane moving).
- `--belt-draw-lattice-creep=flow` (off by default; `on`: by the share above): a lane creeps by
  the net distance its items go on past its exit. `lane_fronts(keys, 2)` (both simulations: as 1, with the front
  item's unique id, its low 31 bits, for the count) gives each drawn lane's front item each update; one the lane
  hasn't had in front (of its last 16) is a gap on, one it had a read putting the items back, a gap back for each
  front since. The running rate (1/256 a tick in 1/1024, over 120 ticks) at 300 or more has a standing lane slide
  on from where it is drawn at that rate (at least 1/256 a tick), under 100 on to the simulation's standing
  front's phase and stand. Its new motion starts at the drawn clock's tick where it is drawn then (set at the
  simulation's tick, the lattice jumped by the change of speed times the drawn clock's lag: lattice hops 1178 ->
  486 a second offline). A lane the simulation has none on stands where it is drawn (creeping: at once; at the
  simulation's speed: after 30 ticks; it went on as it was for good). A lane at the simulation's speed for 120
  ticks whose net rate is under 1000 (about a gap in 16 ticks) stands and takes the simulation's speed again
  only with that rate: the simulation runs on lanes the game holds, and at -62,-26 the lines into a balancer
  let go and were read back again and again, the same fronts coming back with each read. Offline, the restart
  capture replayed at the live cadence (`tests/belt_bs_replay.gd --every-tick=60 --job-every=30`,
  `tools/belt_quirks.py`): lanes drawn standing while the game's moved 3.2% (settle alone 19.1%, the share 2.7%),
  sliding while the game's stood 3.2% (4.7%, 17.3%), frozen spans of 5 s or more 0 (133), hops 420 a second
  (538), jumps as settle's; but phantoms 3.0% (1.7%) and missing 2.2% (0.8%): a creeping lattice's phase lies
  between the game's stop-and-go rest positions, so at a lane's ends a slot and an item go unmatched while it
  creeps. belt_lattice.gd and BeltLatticeNative alike (`creep_flow`, `set_creep_flow`; `tools/belt_draw_diff.py` on
  the restart capture with it on: 207 jobs, 3.96M records, 0 differences). Live, off (the default) against flow,
  `tools/belt_quirks.py` in the client's own view: standing at -62,-26 (Hold 60 UPS, 20 s) lanes drawn standing
  while the game's moved 28.9 -> 1.7%, spans of 8 s or more 303 -> 0, sliding 2.3 -> 2.5%, hops 664 -> 561 a
  second, jumps 66 -> 44 a second, but belt_view_check's visible 97.1 -> 95.7% and phantoms 1.0 -> 2.4%; at
  -272,-14 frozen 5.1 -> 0.3%, spans of 8 s 10 -> 0, sliding 1.3 -> 1.7%, visible 98.0 -> 97.8%, phantoms 0.3 ->
  0.7%; zoomed out at -62,-26 with the owner's settings (Cinematic, shadows ultra, belt distance 128, 20500
  models, view radius 10, camera 0,40,140) frozen 21.6 -> 0.9%, spans of 8 s 138 -> 0, sliding 2.2 -> 4.1%,
  phantoms 1.1 -> 2.3%, hops 2061 -> 1574 a second; the restart test (57 pickup inserters off over the settle,
  on 6 s into 30 s): frozen 22.0 -> 2.0%, spans of 8 s or more 1285 -> 5 (the holds count), sliding 5.1 -> 3.9%, hops 1481 -> 828 a
  second, jumps 27 -> 36 a second, visible 97.2 -> 95.7%, phantoms 0.7 -> 2.3%. What flow leaves unmatched at -62,-26 is near: of the game's items on lattice
  lanes with no drawn item matched, 99.9% have one of their kind within 0.25 tile (33% within 0.1), of the
  slots matched to nothing 95% lie within 0.25 tile of a game item on their lane (the one-to-one match within
  0.15 counts them; the picture shows a packed lane a fraction of a gap off). K19's line-end scene: 282 things
  appearing or vanishing off their motion by default, 593 with flow; the extra 311 are lattice slots at lane
  ends (a creeping lane's slot leaving its end with the next lane standing), 0.1-0.3 tile from the nearest of
  their kind the tick before (the default's 282 have a median of 0.25 tile, 96 over 0.4).
- `--belt-draw-lattice-creep=step` (off by default; `off` and `flow` unchanged; E46): a standing lane steps
  instead of creeping. It stays at the game's rest phase (settle, standing_obs) and stays a standing lane for the
  mask (flow masked a creeping lane end to end, hiding the simulation's standing items past its ends). Each new
  front item on it (`lane_fronts(keys, 2)`, the history flow keeps) queues a one-gap slide at the belt's speed
  through close's slide (`slide_at`, `slide_v`, `slide_more`, at most 4 queued), timed to the tick the items moved:
  from the new front's place while it moves, else half way between the last update and a slide's time before this
  one. Several takes since the last update: while the new front still moves from more than a gap behind its rest
  phase, a slide for each gap behind (at most 5, back to back); once the closing is over by the update, one, as the
  front's place no longer tells and its id doesn't say how many items left between (the simulation's lane fronts
  give only the front item; a count of items leaving each lane would need both simulations to keep one). Picture
  and phase are the same either way (a lattice repeats every gap); a missed gap is a slide not drawn and the items'
  turns a step behind until the lane is written again. On the scenes below no front was ever seen more than a gap
  behind (232 moving fronts on the taker-every-12 one), so the numbers are as before the count. A front a read put
  back drops the slides not yet written. A net rate (flow's) of half the belt's speed or
  more leaves the lane to the usual rules, which take the simulation's speed; a curve whose length isn't a whole
  number of gaps stands, as close has it. A take close slid the lanes behind for (an `ie` hand) isn't slid again
  when their fronts change, nor the other way round (a balance per lane, matched within 90 ticks). Offline on
  K19's line-end scene (`tools/belt_line_end.py --belts 40 --queue 36 --take 25 --feed 6 --ticks 2400`, the replay
  at `--every-tick=60 --job-every=30 --ie-wire=0 --view=-4,4,52,13`, `tools/belt_quirks.py --every 30`), off /
  flow / step: with `--hands-radius 4` frozen 4.66 / 0.39 / 0.27%, frozen spans of 2 s or more 9 / 0 / 0, missing
  0.69 / 1.63 / 0.70%, phantoms 7.95 / 8.20 / 7.96%, hops 139 / 22 / 47; with `--taker-every 12 --hands-radius 4`
  frozen 11.98 / 0.16 / 0.53%, missing 0.31 / 0.92 / 0.36%, phantoms 2.01 / 2.19 / 2.05%, hops 487 / 14 / 146; every
  take sending `ie` (no `--hands-radius`) frozen 0.16 / 2.89 / 0.09%, spans 0 / 2 / 0, missing 0.50 / 1.25 / 0.47%,
  phantoms 0.72 / 0.88 / 0.71%. The cost: lattice lanes drawn sliding while the game's items stood, 0 / 0 / 1.50%
  and 0 / 0 / 4.82% on the hands-radius scenes (0.75 / 0.05 / 0.58% with every `ie`): the simulation learns of a
  take past the hands radius from the bridge's reads, so its fronts change late (slides a median 7 ticks after
  the game's items moved, a tenth over 23), and it runs on lanes the game holds. Owing a gap for each front a
  read put back, so the simulation running on again slides nothing, was measured and left out: on the
  taker-every-12 scene sliding 4.82 -> 3.47% but frozen 0.53 -> 1.43% (the game's own moves owed too). Both
  lattices alike (`creep_step`, `set_creep_step`; `tools/belt_draw_diff.py` 0 differences on all three scenes in
  every mode). Not run live yet (-62,-26, -272,-14). The UI test's `_belt_step_creep`.
- `--belt-draw-early=off`: as before, every change the simulation emits for a tick after the drawn tick
  waits for the next job (its record would show the item at its new place before its time). On (the
  default): a change the records can take without showing anything early is taken now: a start of an item
  whose record stands where the change starts from (a record standing there till t0, then moving, is just
  what the item does), or a continuation of a moving item's record (it reaches the change's lane and place
  at the change's tick at the same speed: a line's end, a closed loop's cut, where the simulation's lines
  hand an item on): the record is made again from where the item is now, across the end, through the
  lanes ahead. Held, such an item was drawn standing at the cut until the next job's result was drawn:
  at -62,-26 a job is about 26 ticks, so on a full closed loop items bunched at the cut and jumped 0.8
  tile, and a run starting between jobs stood and then jumped. With it the simulation is stepped
  `--belt-sim-ahead` 24 ticks past the drawn tick (was 1; never past the newest update), so such changes
  are known in time. Both paths (GDScript and native) take the switch. Live at -62,-26 (Hold 60 UPS,
  `--record 60`, by day): 96.2% visible, 1.9-2.0% phantoms with ahead 64 or 24 (the lattice alone: 95.2-95.7%,
  2.4-2.5%); lattice lanes of a run drawn sliding against a standing neighbour 1.0% of adjacent pairs a job
  (11.8-12.2% before). A job cost 505 ms with ahead 64 (the simulation stepping ahead and 122k held changes
  re-scanned a job) and 426 ms with 24, against about 300 before.
- `--belt-draw-early-stop=off`: as before. A moving item's record runs on to its line's end (the simulation's
  reach), and a stop after the drawn tick it runs into (it catches up with the item in front) waited for the
  next job: the item was drawn running past the stop and pulled back a job's travel then (E46: batches of 20
  and more items on long straight runs whose front flows in bursts, up to 500 a second zoomed out). On (the
  default): `_apply_early` cuts the record to end where the stop is (the stop itself still waits for its tick;
  both records paths, the same arithmetic). The UI test's `_belt_early_stop`.
- `--belt-draw-lead-lag=N` (60): with `--belt-sim-ahead=auto`, the drawn clock is held up to N ticks further
  behind the game than before so the lead fits under the newest update: its margin is at least two job gaps and
  7 ticks where it was 1.5 job gaps and 1. That is half a job gap and 6 ticks more lag: a job gap of 10 ticks
  +11 ticks (0.18 s), 20 +16 (0.27 s), 30 +21 (0.35 s), so the owner's ~35 ticks live becomes about 51. Items
  on belts are drawn that much later than the game has them (the rest of the world isn't). `0`: the lag as
  before (the lead then reaches only about half a job gap past the drawn tick, so early stop alone does the
  work); a smaller N caps the extra lag. Measured on `tools/belt_bursts.py`'s scenes (turbo, 70 belts, the
  lattice off, a job every 30 ticks), jumps a second (tools/belt_quirks.py --every 30): `--mode out` 305.8 as
  before, 174.8 with early stop, 84.1 with the lead and its lag; `--mode take` 131.1, 98.9, 69.7 (the replay's
  `--every-tick` lag 19 for the old margin, 40 for the new one; at the replays' usual lag 60, out 286.6 -> 92.3 ->
  0 and take 129.3 -> 101.0 -> 101.0, take's rest a read shifting a standing run). The replay's lag swept with
  both on: out 84.1 at 40, 39.8 at 46, 0 at 52 and 60; take 69.7, 102.4, 100.2, 101.0. Out's rest at 40 is what
  the bridge's reads tell the simulation late (the front starting off the square), not the lead: a lag of about
  a job gap and 22 ticks clears it, which this margin (a job gap and 13) doesn't reach. Game items seen and
  phantoms (tools/belt_jumps.py) as before on both scenes (out 98.18% / 0.03% before, 98.23% / 0.01% both; take
  98.49% / 0.24%, 98.48% / 0.09%); the line-end scenes (belt_line_end.py, and `--hands-radius 4` with
  `--every-tick=60 --job-every=30`) jumps 0 -> 0 and 10.2 -> 9.6 a second, seen and phantoms unchanged.
  `python tools/belt_ring.py --out <dir> [--puts 10,17] [--watch 5,12]` makes a moving ring the same way (replayed with
  `--replay-bre` so the client's re-reads are answered, as the bridge answers them live).
  `python tools/belt_bursts.py --out <dir> --mode out|take [--tier turbo]` makes the scenes (its header says how
  to replay and score them).
- `--belt-draw-lattice-world=straight`: as before, only straight lanes and undergrounds' visible halves take the
  map's phase while moving; curves and splitters slide at the simulation's front item's phase. `all` (the
  default): every lattice lane does. Any phase draws a full lane within 0.125 tile of the game's items, but
  where two lanes' lattices meet (a splitter's inputs overlap its outputs by the 51 buffer: an input's exit sits
  0.2 tile into the output half, and the game holds an input item and an output item at the same spot there; a
  curve's last slot reaches past its entry) their phases must agree, or the check's one-to-one matching leaves a
  game item without a slot and a slot without an item. On a backed-up balancer the simulation's front is a tick
  or two off the game's (32-64 at turbo speed), and a lane once moving was never re-phased on a speed change: at
  -62,-26 one game item in ten on splitter lanes had no slot within 0.15 tile and 7% of the slots there were
  phantoms (scratch decompose.py over the belt-rate round's recorded runs).
- `--belt-draw-lattice-standing=world`: as before, a standing lattice (the simulation's front on the lane
  standing, or none there) takes the map's phase on straight lanes and the simulation's front's on others. `obs`
  (the default): the bridge's last read or check of the lane (`sl`, `pc`: its front item's position mod 64), where
  the game last showed its items; set again when a new read or check differs. A standing lane's items are exactly
  there until it moves; the map's phase was up to 0.125 tile off (a run backed up at phase 32 sits at the check's
  limit, and the greedy matching then takes a neighbour's slot), and a standing lattice at a high phase has one
  slot fewer than the lane's items. A lane stopping keeps the phase it was drawn at until its next read or check.
  Emulated on the recorded dump (the slots re-placed and re-scored): as drawn 96.35% visible / 1.68% phantoms,
  the map's phase on every moving lane 96.75% / 1.25%, with the observed phase on standing lanes 96.86% / 1.13%,
  the game's own phase on every lattice lane (the ceiling) 97.51% / 0.48%. Measured: see "The belt gap at
  -62,-26" below. Both twins (belt_lattice.gd, BeltLatticeNative) take both switches alike.
- `--belt-draw-lattice-native=off`: the lattice made in GDScript (`belt_lattice.gd`), as before. On (the
  default when the C++ library is loaded and the simulation is `BeltSimNative`): `BeltLatticeNative`
  (`client/native/belt_sim/src/belt_lattice_native.cpp`), belt_lattice.gd function for function, writes the
  same records (`tools/belt_draw_diff.py`: 0 differences between the two on a capture; the dump's `lat_native`
  says which ran). At -62,-26 the GDScript lattice cost 25-70 ms a job (half a second when the view moved and
  every lane was planned again, so walking paid it every few steps); the C++ one 1-3 ms.
- `--belt-draw-lattice-turns=slot`: every lattice slot keeps a turn of its own, as before K14 (owner: "items
  change their orientation as they move on the belts"): a slot slides one gap and wraps back while the slot
  ahead takes its item on, so an item seen sliding along took the next slot's turn every quarter tile. On
  (`item`, the default): each drawn item keeps one turn. A lane's slot k holds who its item is (texel 2 x:
  the lane's `who` + k, texel 2 y: its run's seed, texel 3 z 2) and the shader adds the periods slid since
  the record's clock and hashes both into the turn (belt_path.gdshaderinc `belt_lattice_turn`, item_cards.gd
  `lattice_turn`: the same range as every item's turn and the same pile rule). A lane written again (a new
  speed, its phase made again, its piles) keeps who its items are, each new slot taking the nearest old
  item's as both are drawn when the update is first drawn (`Job.fold_tick`: the drawn clock runs behind the
  simulation, so a lane that stops is drawn jumping by its speed times that lag); a new lane takes them from the drawn lane its items go on into or come from (so an item keeps its
  turn from belt to belt, round corners too), else from the map along its exit's direction. No per-frame CPU
  work; both twins alike (the UI test's `_belt_lattice_turns` compares them). An item still takes a new turn
  where it passes between a lattice lane and one drawn from the simulation (whose items turn by their unique
  ids), and once round a closed loop where the run's identity meets itself.
- `--belt-draw-lattice-mask=ends`: as before, a lattice lane marks the mask's cells along its centre line from end
  to end, so where its entry's point lies on a cell's edge (a lane going west or north) the cell it marks is the
  lane behind's first one: that lane's front item, standing at its exit (line position 0), was hidden while that
  lane was drawn from the simulation (the owner's playtest, K19: an inserter's take from a backed-up line gives its
  lane up for the simulation's items, and that lane's front item was gone from view until it was a lattice again;
  in `tools/belt_build_mine.py`'s mine scene the items standing at the front of each belt of the queue behind the
  gap). On (the default): a standing lane's entry point is taken a 64th of a tile inside it. Its exit's point
  still marks the cell past it (a lane going east or south: the lane ahead's last one), and a moving lane marks end
  to end: with every cell past either end left unmarked, the restart capture at -62,-26 (below) had 2.15% phantoms
  against 1.73% (the simulation's items just past a lattice's exit, where its slots draw the game's). A lane that
  starts or stops moving is marked again. Both twins (`_mark`), and tools/belt_view_check.py's `lane_cells`
  (`BVC_MASK=ends` scores a run made the old way).
- `--belt-draw-lattice-mask=entry`: as before (the default above), a lane's exit point marks the cell past it on a
  lane going east or south (the lane ahead's last cell) and a moving lane's entry point the cell past it on a lane
  going west or north (the lane behind's first). Where that lane is drawn from the simulation (a take's lane given
  up, a lane short of full) its items vanished in that cell as they went through it: a one-item gap fixed at the
  belts' join while the line moved, gone once it stood and was a lattice again (the owner: "after pulling items off
  a full backed up belt these gaps appear and items move past but the gap remains in the spot until it stops
  again"). On (the default, `own`): every lane's ends are taken a 64th of a tile inside it, moving or standing, so a
  lane marks its own cells only. Offline (`tools/belt_bursts.py --mode take --tier yellow --belts 40 --ticks 1300
  --f --takers 2 --takers-from 10 --period 15 --take-window 100,900 --release 300,700`, replayed as below at
  `--job-every=30`): going east (`--east`) 1.16% of the game's item-ticks undrawn against 0.76% (the join's cell
  had 27 items in turn go through it undrawn), phantoms the same but for the run's own exit (items on the
  unrecorded gate belt now shown); going west 0.57% against 0.42%, phantoms the same. Both twins (`_mark`),
  `BVC_MASK=standing` scores a run made with `entry`.
- `--belt-mask-tiled=off`: upload all 16 layers of the `f3d_belt_mask` `Texture2DArray` whenever the lattice mask
  changes, instead of uploading only the dirty `512 × 512` tiles (default on; 256 KB per dirty tile vs 4 MB full
  re-upload).
- `--belt-native-decode=off`: decode `bs` message body lists (`sl`, `sh`, `ew`, `pc`, `pu`, `of`) in GDScript instead
  of `BeltSimNative.apply_bs_body` (default on when both `BeltSimNative` and `BeltLatticeNative` are active).
- `--belt-draw-lattice-open=off`: as before, a moving lattice lane marks all its own cells whatever draws the lanes
  beside it. A moving lattice has the map's phase and a line's items whatever phase their history gave them (up to
  0.125 tile apart); where the lane ahead is drawn from the simulation (read short of full: a gap of 67 or more, a
  line fed by inserters or a merge) the game's item at the lattice's exit, its slot already wrapped to the entry (the
  lattice ahead), was hidden by the mask until it crossed: every item vanished for a few ticks at the join, a gap
  standing in the moving line (the owner: "they don't just move in unison"). Likewise at the entry of a lattice
  behind the items, where no lattice feeds it. On (the default, with `--belt-draw-lattice-mask=own`): a moving lane
  more than 4/256 ahead of the simulation's front item leaves its exit's cell unmarked when the lane ahead isn't a
  lattice at its speed, one behind it its entry's cell when none feeds it; the simulation's item shows there beside
  the slots (at most the phases' difference apart, an overlap rather than a gap). A lane in step keeps its cells.
  Offline (`tools/belt_bursts.py --mode out --open 99999,99999 --shut 1,1 --feed --feed-loose 0.1 --tier yellow
  --belts 40 --ticks 2400`, replayed as below): the game's item-ticks undrawn mid-run (belts 2-38) 0.40% against
  0.03% (going east, `--east`: 0.38% against 0.02%); belt_quirks' phantoms 1.36% against 4.01% (the overlaps: a slot
  and the item it stands for both drawn in the open cell), and on a tightly packed line (no `--feed-loose`) 0.19%
  against 1.77% at the run's two ends. Both twins (`_open_ends`, `_mark`; the dump's ids column 7 says a lattice
  lane's open ends, which tools/belt_view_check.py's `lane_cells` follows). In the debug menu's Simulation tab.
- `--belt-draw-handover=old`: as before, with the lattice's open ends (above), the open cell's slot and the
  simulation's item there were both drawn, up to 0.125 tile apart (phantoms 1.36% -> 4.01%). On (the default): the
  slot whose gap reaches into an open end's cell hides while its item is the simulation's to draw there: at an exit
  from where its item comes into the cell, at an entry until its item has left it (the phases' difference at the
  simulation's front item, 3/256 more for a line's items a little off one another; the slot record's texel 3 y,
  read by belt_path.gdshaderinc, belt_view_check and `drawn_lattice`). Offline, the open-ends scene above: belt_quirks'
  phantoms 4.01% -> 2.36% (east 4.11% -> 2.54%; tightly packed 1.77% -> 1.32%), missing 0.39% -> 0.40%, undrawn
  mid-run 0.03% either way; the take scenes unchanged. Both twins, in the debug menu's Simulation tab ("Clean
  handover").
- `--belt-draw-turn-id=old`: as before, a lattice lane's items were who its neighbour's or the map's formula said and
  a simulated item turned by its unique id, so an item changed its turn where a lattice lane met one drawn from the
  simulation. On (the default): the simulation numbers each item along its run when it first comes into a line (one
  behind the item ahead; belt_sim.gd `_num`, BeltSimNative alike, take_changes()' `num`, lane_fronts speed_of 3), a
  simulated item turns by its number (belt_items.gd and BeltDrawNative), and a lattice lane is seeded from the
  simulation's front item on it when written, and again once moving in step for 2 s when its items' numbers have run
  ahead of its slots (not a standing lane, which settle stands behind its run on purpose, nor a ring). Offline, turn
  changes (a game item's drawn turn differing from the tick before): belt_bursts --feed --feed-loose 0.1 5098 -> 2150
  (at a lattice/simulation join 4342 -> 233), east 4551 -> 1790 (4120 -> 157), the take scenes' joins 317-1300 -> 8-22;
  phantoms, missing and undrawn unchanged by it. Both twins, in the Simulation tab ("Items keep their turn").
- `--belt-draw-edge-shut=off`: as before, a moving lattice lane leading nowhere loaded (the square's edge) opened its
  exit like one beside a lane drawn from the simulation, so the simulation's items stopped at its end as a guess
  (EDGE_STOP) showed there, stacked, while the game's ran on. On (the default): an exit opens only where its items go
  on (BeltSim.leads_on: into a lane, a side-load, a splitter). Offline: loose-fed phantoms 2.36% -> 1.56% (most were at
  the run's exit), tight 1.32% -> 0.19%, east 2.54% -> 2.42%; missing 0.40% -> 0.51% and 0.03% -> 0.19% (the game's
  item at the very edge, its slot wrapped a few 256ths early), undrawn unchanged. In the Simulation tab ("Shut edge
  ends").
- `--belt-draw-lattice-close=off`: as before, the lanes behind a take's hole in a standing lane stood while the
  game's line closed it up (with settle, a gap on is the same picture), and the take's lane, given up for the
  simulation's items at the bridge's read, slid alone (the owner, K19: "the items dont slide forward as a group to
  fill the space instead the back item moves into the next one and the front item moves out of the static to
  fill"). On (the default, with settle): a take on a standing lane (or one not drawn) has every drawn standing lane
  behind it (`feeds`, its straight run back) slide one gap from the take's tick at its belt's speed and stand
  again, each slot the item that was behind it (who + 1), as the game's packed line closes up; the take's lane is
  given up for the simulation's items at once. A slide is each slot's record as a moving lattice's with its clock
  held within [the take's tick, a period after] (texel 1 w the start, texel 1 y the periods: 1;
  belt_path.gdshaderinc, belt_items.gd and BeltLatticeNative `drawn_lattice`, tools/belt_view_check.py), so it
  stands before and after wherever the drawn clock is when it is written. While a lane slides its phase isn't
  checked (a read of it mid-way through the closing, the UI test's, put it standing at the read's place and the
  slide was lost). A lane whose standing slots aren't a moving lane's (a curve whose length isn't a whole number of
  gaps) stands as before; a second take while a lane slides closes after the first (`CLOSE_MORE` more at most); a
  take on a lane while it slides hides the slot that holds the hole as the slots wrap. The UI test's
  `_belt_line_end` checks it (the lanes behind drawn 0.117 tile off their places mid-way, back on them after).
- `--belt-draw-lattice-sim-full=off`: as before, a moving lane stays a lattice while the bridge's last read or
  check found it full: a belt mined out of a packed moving line left the belts in front drawn full and moving until
  the bridge's next drift check (the owner, K22: "the belt in front stays full as it moves forward instead of
  emptying immediately few seconds later it shows the empty spaces"). On (the default): for `FED_GONE_TICKS` (30 s)
  after a belt behind a lane was removed (belt_items.gd `_feed_gone`: a lane dropped two tiles or more inside the
  bridge's square, or a belt Zenith removes; the lanes it led into, on along their run to a splitter), a moving
  lane the simulation has items on but fewer than a full lane's is given up (its full forgotten until the bridge's
  next read or check says so again). Only there: the simulation is often short of the game on packed lanes (what
  the lattice draws them for), and a lane fed from outside what is sent empties in it between the bridge's reads;
  with every lane the simulation had short given up, the restart capture had 6.1% of the game's items in view
  missing (0.8%), and the far end of `tools/belt_build_mine.py --source` flapped every 24 ticks.
- `--belt-draw-lattice-tail=off`: as before, a moving lane a packed block had filled stayed a lattice after the
  block's tail had passed it, till the bridge's next read or check (on a ring with a packed block going round,
  `tools/belt_ring.py`, the lanes it left were drawn full about 100 ticks more). On (the default): a moving lane the
  simulation has short of full, or any lane it has no items on, is given up when the simulation's line behind its
  entry holds nothing for two gaps on lanes it knows all that feeds (`BeltSim.lane_tails`: not a lane fed from outside
  what is sent, the square's edge, a side-load or a splitter, where the simulation empties between reads).
- `--belt-draw-lead-max=N` (32): the most ticks a job's lead is (how far ahead a record that ends is made again, and
  how far a path across its end reaches); 8 as before. A busy client's jobs (every 30 ticks) had their lead held at
  8, so an item whose record ended at a curve stood there up to 22 ticks and jumped on (the ring: 20 jumps a second).
  `tests/belt_bs_replay.gd` sets each job's lead as the client does from `--job-every` (`--job-lead=N` to fix it;
  before, it was always 2).
- `--belt-draw-lattice-start=off`: as before, with settle a standing lane takes a new speed only once the
  simulation has had it moving for two gaps' time, then from the map's phase: a belt built at a backed-up line's
  end had the line's packed belts stand for 16 ticks (yellow) while their items ran on onto it (drawn from the
  simulation there), each belt's front slot left standing at its exit and a gap opening behind the new belt's items
  (the owner, K16: "there is a bit of a gap between the new belt items and the previous also leaves some ghosts at
  the end where it is pulling forward from for a few seconds"). On (the default, with settle): a drawn lane whose
  next lane is new (the simulation's `links_ver` changed and its `next_of` with it: a belt built in front of it)
  lets its straight run back go for `RELEASE_TICKS`: each standing lane of it the simulation then has moving starts
  at once, from where it stands, on the tick its items started (its record's clock held there before, texel 1 w).
  Other starts wait as settle has them, from the map's phase (every start from where it stands cost the restart
  capture 0.4% more missing and as many phantoms: its neighbours keep the map's phase).
  `--belt-draw-lattice-start=stops` (off by default): a moving lane the simulation has standing also goes on to the
  tick its lattice comes to the standing front's phase and stands there (its clock held after: texel 1 y the
  periods from its start), standing in the lane's state once the drawn clock is there; moving again before that, on
  from the tick its items went on. On the restart capture lanes drawn standing while the game's moved 19.0 ->
  13.4% of the item-seconds in view, frozen spans of 2 s or more 1546 -> 927, lattice hops 554 -> 264 a second,
  but sliding while the game's stood 4.9 -> 7.2%, phantoms 2.15 -> 2.34% and missing 0.83 -> 1.04% (the
  simulation runs on lanes the game holds, which the stop at once, ahead of the drawn clock, hid).
  Measured offline, the four switches together against all four off (each scored with its own mask; both twins
  alike, `tools/belt_draw_diff.py` 0 differences on each scene and on the restart capture):
  `tools/belt_line_end.py` (K19, seed 1, 3,600 ticks, 63 takes): game items seen 99.35% -> 99.99%, things
  appearing or vanishing off their motion 266 -> 164 (`tools/belt_jumps.py`), missing 0.65 -> 0.01% of the
  item-seconds (`tools/belt_quirks.py`; on the take's lane 13.6 -> 0.3%); `tools/belt_build_mine.py --scene
  extend` (K16, a belt built at the end of a line backed up 16 belts, another 120 ticks on): seen 98.97 -> 99.98%,
  appearing or vanishing 91 -> 82; `--scene mine` (a belt mined out of a moving line, not packed): seen 95.54 ->
  99.91%; `--scene mine --source --spacing 64` (K22, a packed moving line): phantoms 2.06 -> 0.16% of what is drawn
  (44 a tick at the worst, the belts in front drawn full -> 25 at the mine), seen 99.84 -> 99.67% (the belts given
  up beside moving lattices, whose cell past the exit hides the item just past it). The restart capture at -62,-26
  (`tests/belt_bs_replay.gd --every-tick=60 --job-every=30`, `tools/belt_quirks.py`): all four on as the old way within noise: lanes
  drawn standing while the game's moved 19.2 -> 19.0% of the item-seconds in view, sliding 4.7 -> 4.9% (the
  closings' slides), phantoms 1.72 -> 1.73%, missing 0.84 -> 0.84%, holes 0.29 -> 0.28%. Live (Hold 60 UPS,
  tools/belt_view_check.py, tools/belt_walk_check.py): -62,-26 97.2% visible / 0.9% phantoms, -272,-14 98.1% /
  0.3%, walking at -62,-26 99.4% / 0.8% (before: 97.1 / 0.9, 97.7-98.0 / 0.3, 99.3-99.4 / 0.8-0.9).

The 0.2.1 performance hotfix's switches (art-src/perf-plans/belt-sim.md section 6; all client-only, both records
paths alike). Its counters go into belt_items.gd's `stats`, so the stutter probe's `join.belt_stats` shows them:
`later` (changes waiting after the last job; `later_max` the most), `waiting` (items with changes waiting, with
`--belt-draw-later-tick`), `early_tries` and `early` (early tries and takes, summed), `drained` (items whose
waiting changes a job looked at), `ask_view` / `ask_lat` / `ask_out` / `ask_unknown` (lanes asked for again,
`bre`, by why: a failing check in view, on a lattice lane, out of the planned view, meta never come) and
`ask_held` (failing checks not asked for, for their interval), `slots` (item slots in use, piles' copies too) and
`slots_hidden` (of them, the slots of items whose motion lies on lattice lanes all along: hidden by the mask in
every frame), `parked_view` / `parked_lat` (parked items by why), `lat_lanes` and `lat_slots` (the lattice's lanes
and slots), `lat_parks` / `lat_unparks`. The slot and parked counts are taken every 16th job (on the GDScript path
only while a probe runs or with `--belt-draw-dump`); the dump's job lines carry them too (`asks`, `gauges`).
- `--belt-draw-later-tick=off`: the changes that take effect after the drawn tick wait in one list, as before,
  every one looked at and tried early (`--belt-draw-early`) every job, with a hash set made from nothing each
  time: half the worker's time at the owner's base (about 35,000 waiting, 34 jobs a second). On (the default):
  kept by item and filed by the tick they take effect at (`belt_draw_native.cpp` `_drain_due`, belt_items.gd's
  twin). A job takes the items whose first waiting change is due, and tries early again only an item that
  changed since its first was tried (its record planned, parked, unparked; a start waiting for the item's own
  tick, once the drawn tick is there), or every waiting item when the lanes' links may have moved (a lane's meta
  changed or one dropped, a relink since the last job or one pending: an early take walks the lanes ahead). Any
  other try would fail as the last did, so the takes are the list's, item by item, and the records the same
  (`tests/belt_bs_replay.gd` on three offline captures, both twins, off and on: 0 differences in
  `tools/belt_draw_diff.py`). The simulations' new `links_ver` and `links_pending()` tell the drawing when links
  moved; the coalescing map is kept between jobs; both twins take the items in order of their ids, so they hand
  out slots alike. Offline (at most about 5,000 changes waiting, against about 35,000 at the owner's base) early
  tries fell 55% and the C++ job's applying 17%; the GDScript twin's applying rose 28% there (its fallback may
  want it off).
- `--belt-draw-skip-same=off`: every job is given a fresh copy of the kinds' looks and a fresh list of the far
  icons' chunks (`belt_lanes.gd built_chunks()`, a dictionary of every far chunk, which the C++ side made into a
  set again), the far icons are handed the square every result (every icon material's parameters set), and
  `f3d_belt_lattice_on` set every result, as before. On (the default): each only when it changed
  (`belt_lanes.gd chunks_ver`, belt_items.gd's own count of its looks' changes); the native records keep the
  last ones given.
- `--belt-draw-small-pages=off`: the records' pages (`f3d_belt_records`, `f3d_belt_lattice`) are 16 rows of
  1,024 texels (256 KB, 4,096 records) and the texture array starts with one, doubling as the first load grows
  it (each doubling makes the array again: every page uploaded, a 1.5-3 ms frame), as before. On (the default):
  4 rows (64 KB, 1,024 records), 8 at the start. One record written sends its whole page up, a copy on the worker
  and `update_layer` on the main thread (about 22 pages a job standing at the owner's base, 186 MB a second at
  256 KB). `belt_path.gdshaderinc` takes a page's size from the texture's, so both work.
- `--belt-draw-park-lattice=on`: an item whose motion lies on lanes the lattice draws all along (its place and
  its reach ahead: how far lattice lanes go on past its lane's exit, worked out when the lattice's lanes change)
  is parked as an item out of view is: its motion kept, no slot, no record, nothing for the GPU (the mask hid it
  in every frame of that motion). The lattice is updated before the records now and gives its lanes added and
  removed; items on a lane that leaves the lattice are planned again from their motion in the same job, and
  those on a lane dropped from the square stand where they are for the far icons' hand-over, so a belt is never
  bare. An item whose motion runs off the lattice's lanes stays drawn and masked as before (it shows the moment
  it glides out). Quality marks (`position_of`) of a parked one come from its motion. Off (the default): as
  before. Offline it wrote 45-96% fewer records (the replay's three captures, a drifting view on one), both twins
  alike; live on the owner's base it is worth 1.0 ms of GPU but drew 3.7% phantoms at -62,-26 (the gate is 2%;
  1.3-1.4% off): items handed back from parking land in the wrong place for a while. Off until that is fixed.
- `--belt-sim-ask=view` (the default): lanes asked for again (`bre`) by what shows: a lane the lattice draws only
  when its check's count is wrong (the simulations now say per failing check whether the count differed,
  `mismatch_n`), at most every 30 s (front, back and ids drifting on a full lane are what the lattice ignores; such
  a lane is asked for the moment it leaves the lattice), a lane outside the planned view every 12 s, doubling to 60
  s while it keeps failing and back to 3 s once the view reaches it; a lane in view the lattice doesn't draw every
  3 s as before. `--belt-sim-ask=all`: every failing lane every 3 s, as before. (art-src/perf-plans/belt-sim.md B1:
  735 asks a second standing at the owner's base, 1,100-1,200 on laps; bridge.md's change 10 on the client's
  side.) Offline (`--replay-bre`) the simulation's own score by place fell, but live it held: at -62,-26 97.9%
  of the game's items drawn and 1.1% phantoms (`all`: 97.6-97.7%, 1.3-1.5%), at -272,-14 98.4% and 0.6% (the
  same), with 45-75% fewer lanes asked, the client's belt job 15-25% cheaper and the bridge's `bs.bre` 0.3 ms
  lighter (art-src/perf-plans/after.md 6).
- `--belt-sim-ask-near=off`: a job's asks in the simulation's order. On (the default): nearest the middle of
  the view first (the square's middle with no camera); the bridge reads asked lanes in the order asked, at
  most `bre_cap` (192) an update, so the near ones are read first when it can't read them all.
Inserter arms (client/scripts/world/inserter_arms.gd; the mod samples every hand's position and held
item every 6 ticks, `ih`):
- `--inserter-arms-clock=belt|wall` (belt): with `belt` the arms are drawn at the game tick the belt items
  are drawn at (belt_items.gd's drawn tick; the arms' own game clock two updates behind when no belts are
  drawn), each arm keeping its last seconds of `ih` samples by tick and the hand played between the two
  samples round the drawn tick as Factorio moves it (inserter_swing.gd: a turn and a stretch at the
  prototype's speeds, `eprops` rs/es times quality, out to the pickup and drop points, `eprops` ip/id turned
  by the direction, waits only there, the item changing hands as the hand leaves an end; a belt pickup
  solved for where and when the hand met the item). So a fast inserter's whole 12-tick swing shows and
  the hand closes on a belt item the tick the belt loses it. `wall`: as before, each arm gliding on the
  wall clock from an update's arrival towards the newest sample (about 10 ticks behind the game, the
  swings cut short at both ends, and 30-90 ticks ahead of the belts at -62,-26). Measured live (tools/inserter_check.py, Hold 60 UPS, by day, 20 s), wall -> belt: the drawn hand's error against the game's hand at the tick it stands for, while the hand moves, 0.26 -> 0.13 tile at -272,-14 and 0.67 -> 0.12-0.14 at -62,-26; drawn swings covering 76% -> 98% and 55% -> 97-98% of the true arc, reaching both ends 8% -> 95% and 1% -> 80%; at a belt pickup, when the belts' drawn tick reaches the take, the hand 1.1-1.3 -> 0.27-0.36 tile from the take spot and holding the item 35-65% -> 74-87% of the time (92-99% within 6 ticks); the arms' tick 13-39 ticks ahead of the belts' -> 0. Cost: 0.9/1.1 -> 1.1/1.3 ms a frame on average with 55/93 arms (the plans every 6 ticks; p90 1.5/1.1 -> 2.7/2.4 ms); the bridge's `inserters` step and `ih` bytes unchanged (0.08-0.10 ms a tick, 16-18 bytes a hand). Belts unchanged (visible 97.5-97.6% / 96.1-96.3%, phantoms 0.9% / 2.0-2.2%). At -62,-26 the client loses ~18% of the bridge's datagrams (`bs` too): a lost `ih` update makes a 12-tick pair, where a half-circle turn's side is a guess.
- `--inserter-events=off|items|on` (off): with `on` (and the belt clock) the hello asks the mod for `ie`: what each
  hand did as it happened (inserters.lua: picked {tick, count, item, where}, dropped {tick, remaining,
  where}, a status change, a position now and then and once or twice mid-swing, gone; docs/PROTOCOL.md)
  instead of the `ih` samples every 6 ticks. The mod keeps the square's inserters by chunk (searched once,
  again when something is built or removed there or every 600 ticks) and checks each hand (held count
  and status, two cheap reads) when something can have happened: on its way, at the tick its speeds say
  it arrives, so the pick and drop ticks come out exact; at a belt every tick (`/f3d-ih chase 2` for
  every other); waiting at a chest or machine less and less often, up to every 30 ticks (`/f3d-ih idle`);
  without power or disabled every 6 ticks with its position (the client then draws it from the positions
  as samples); at most 48 hands a tick (`/f3d-ih budget`), a record saying how many ticks late it may be
  when a check waited. Each record goes in the next 3 messages, 2 ticks apart (`/f3d-ih repeat`,
  `every`), so a lost datagram loses none. The client plays the swing from the last event at or before
  the drawn tick (inserter_swing.gd plan_events): a hand that took goes to the drop at its speeds and
  waits there until it dropped, one that dropped goes back and reaches for the item it takes next where
  it took it (so a bulk hand shows its first item at the grab, and the sweep's side comes from the
  mid-swing positions, not a guess); an uncertain pick is dated back by the exact drop after it.
  `/f3d-ih events on|off|auto` sends events to any client, to none, or as the hello says (auto);
  `/f3d-ih samples on|off|auto` the same for `ih` (auto: unless events go); `/f3d-ih` says what is sent,
  the hands' states and the checks a tick; `/f3d-ih reset` forgets the cache. Nothing of this is in
  `storage` (the cache and each hand's state are module-local: they only decide what is read and sent,
  so peers whose tables differ don't desync; after a load every hand is synced again within a tick).
  `items`: the hello asks for both (`ie` 2): the swing is drawn from the samples as before (they follow
  the game's hand, which is the item as drawn, lifted mid-swing, which the events can't) and the held
  item alone follows the events: it appears and vanishes at the game's own pick and drop ticks when the
  mod saw them exactly. `off`: the samples as before (an older mod, the menu's recorded stream and
  `wall` use them too).
  Measured live (tools/inserter_check.py, Hold 60 UPS, 20 s, the same runs as the belt numbers; `off`
  -> `on` -> `items`): at -272,-14 the drawn hand's error against the game's hand while it moves 0.12 ->
  0.48 -> 0.12 tile (the game's `held_stack_position` is the item as drawn, lifted ~0.5 tile mid-swing,
  which the samples follow and the events' straight legs can't; the event path's sweep side is also
  wrong in a share of cycles: p90 1.3), swings covering 98% -> 72% -> 98% of the arc, the hand holding
  the item at the frame the belts' drawn tick reaches a belt pickup 75% -> 100% -> 62% (96-100% within 6
  ticks either way), the drawn item appearing or vanishing within a tick of the game's count change 71%
  -> 74% -> 54%; at -62,-26 (the client losing ~18% of datagrams there) 0.15 -> 0.67 -> 0.12, 96% -> 90% ->
  96%, 77% -> 89% -> 45%, 50% -> 40% -> 33%. The bridge's records themselves: 70-84% at the exact tick,
  75-89% within one, 5-6 of 330-820 changes missed; the rest late by the wait between checks at a chest
  (up to 29 ticks). Cost: the bridge's `inserters` step 0.10/0.09 -> 0.17/0.20 -> 0.17/0.27 ms a tick
  (16-26 hand checks a tick), bytes 173/128 -> 89/115 -> 224/289 a tick, the client's arms 1.1/1.5 ->
  1.2/2.1 -> 1.0/1.6 ms a frame. Belts unchanged (97.2-97.6% / 0.78-0.84%, 96.2-96.3% / 1.7-2.2%). So
  `off` stays the default: the events are exact where the hand is checked every tick or two (belts) and
  robust to lost datagrams, but drawn alone they lose the lifted look and a share of the sides, and with
  the samples they cost more than they add yet (step 4: the belt item handed to the hand at the event's
  tick is what they are for).
- `--inserter-handoff=on|off` (on): the belt item an inserter takes leaves the drawn belt as the drawn hand
  closes on it, and the one it puts appears where and when the hand lets go (owner: "have them picking up the
  items in the animation"). The hello asks for `ie` (as `items` when `--inserter-events` is off: the pose from
  the samples, the held item from the events) and `ho` 1, for which the mod adds a `placed` record to each drop
  onto a belt: the item's unique_id, lane and line position, read off the belt at that check (inserters.lua;
  docs/PROTOCOL.md `ie` kind 6). belt_items.gd hands each pick from a belt to its simulation as a take on the
  event's tick (BeltSim.take_at, both twins: the items of the kind nearest the hand on the belt's lanes, as
  many as the pick added, within 0.625 tile; not when a read of those lanes as of that tick came first), each
  placed record as a put (put_at: that uid on its lane then). The taken item is gone on the take's tick; its
  record hides from that tick (texel 3 w, the shader), guessed ahead by BeltSim.peek_take when the event comes
  before the simulation reaches its tick (a guess the take didn't make is shown again); a put item is made a
  job early and hidden till its tick (w negative); a lane drawn as a lattice gets the hole the take leaves
  (belt_lattice.gd hole, both twins: the slot's texel 3 x), until the bridge's read makes it the simulation's
  again. The arms are steered onto the item's drawn place over the last 4 ticks before the grab (or the put's
  place before the drop) and eased back over 3. The bridge's lane reads stay the correction: a wrong guess (the
  game kept the item) comes back with the next read, a put the read already holds is left as it is.
  `--inserter-handoff-slack=N` (3): the simulation is stepped at most N ticks short of the newest update so
  the events for those ticks are in (no measurable gain at -62,-26; kept for slow links).
  `--inserter-handoff-margin=N` (0): the drawn clock held N more jobs behind the game, so the job that learns
  of a take is drawn before its tick: at -62,-26 with 1, the hand from the item at the grab 0.22 (p90 0.41)
  tile instead of 0.49 (1.69), the item leaving within a tick of the hand closing 58% instead of 51% (p90 4 ticks
  instead of 9), drops 48% instead of 27%; the belts drawn ~25 ticks behind the game instead of 6-14.
  Measured live (tools/inserter_check.py section 7 with the run's --belt-draw-dump; Hold 60 UPS, by day, 20 s;
  off -> on, 2-3 runs at -62,-26, 1 at -272,-14): at a pickup from a belt, the drawn hand from the item at the
  drawn moment it leaves the belt 1.2-1.5 -> 0.45-0.55 tile on average (p50 0.8-1.4 -> 0.07-0.20; -272,-14 1.42 ->
  0.38, p50 1.35 -> 0.06), the item leaving 19-32 ticks after the hand closed -> about a tick (p50 0.9-1.3, 44-51%
  within a tick; -272,-14 6.6 -> 0.9, 59%); at a drop onto a belt, the item appearing 10-20 -> 1.4-3.1 ticks
  after the hand opened (p50), the hand 1.5-1.8 -> 0.4-0.8 tile from it. The client's takes: 93-95% confirmed
  by the bridge's next read of the belt (the rest the read put right); puts 99.7-100% found by uid in the next
  read. Belts held: -62,-26 visible 96.7-96.9% / phantoms 1.0-1.3% (off this round 96.7-97.0% / 1.7-2.1%),
  -272,-14 98.0% / 0.36% (98.0% / 0.43%). Cost: the bridge's `inserters` step 0.11-0.12 -> 0.28-0.31 ms a tick at
  -62,-26, 0.09 -> 0.24 at -272,-14 (the events with the samples, as `items`, and the drop belt's lines read at
  each drop); the arms 1.8-1.9 -> 1.8-2.1 ms a frame; the hand's error against the game's unchanged (0.14 tile
  moving). `off`: as before (the read's diff takes the item off up to a job after the read, 0-6 ticks after the
  take, wherever the simulation has carried it by then).
- `--inserter-grip=on|off` (on): the item a hand carries is drawn in its grip, from the pick to the drop (owner,
  K8: a modeller's rigged inserter closed its pincers until they met, through the item, which they hid). A rig's
  pincers close onto the item's sides (`ModelRig.HELD_HALF`, 0.1 tile either side of the plane between them:
  item models are 0.2-0.27 across) and the item's middle is at the grip, half way along them; Wube's arm (Zenith's
  own inserters) reaches the hand's place with its claw's middle (the wrist did, the claw ending 0.15-0.3 tiles
  past it), the item between its fingers; a model turned with the hand, an icon card keeping its slight turn;
  the grip no lower than 0.03 tile over where belt items are drawn (a modeller's belts are taller: Vasillo's tops
  at 0.25). `off`: the item's base at a rig's grip or 0.14 below the wrist, the pincers meeting, as before.
  Checked by model_textures_test.gd (`-- --rig=<a modeller's inserter.glb>` for theirs) and
  inserter_events_test.gd (a rig fed a pick and a drop as `ie`, drawn frame by frame).
- `--inserter-rest-arms=on|off` (on): an inserter the bridge sends no hand for draws its arm at rest, the hand
  empty over its pickup (Factorio's idle hand waits there). The bridge sends hands only within
  `f3d-detail-radius` of the focus (24 tiles by default, at most 64), and no model carries an arm, so every
  inserter past it stood without one (owner, K12). Three plain boxes in the arm's paint (`ARM_TINTS`, else the
  prototype's colour), riding the hills, every resting arm in one MultiMesh without shadows (36 triangles an
  arm); worked out per chunk when its entities change (at most 0.3 ms a frame) or one of its inserters' live
  arms comes or goes (at once, so no arm is drawn twice or missing), put together at most every 0.25 s, never
  per frame. `off`: none, as before. Not measured on a big base; checked by inserter_events_test.gd.
- `--heat-glow=heat|always` (heat): a heat pipe model's glow (FUE5's heat pipes' copper) follows its temperature,
  the bridge's `ht` (fluids_power.gd): lit from 350 °C (Factorio's heat pipe minimum_glow_temperature, where its
  heated pictures start), easing on and off, dark below it and where no temperature is heard (past the bridge's
  fluids radius). On or off, not brighter with more heat. `always`: lit all the time, as any glowing model without a
  state. Headless only (anim.gd STATE_HEAT), not seen in a window.
- `--gate-state=guess`: a gate's doors guess from what is near whatever the bridge sends, with the fixed 4-tile
  vehicle reach (as before the bridge sent gates). Default: a bridge with `/f3d-perf gate_state` on (default) sends
  each gate's real state within 64 tiles of the focus (`st`: 0 closed, 1 opening, 2 opened, 3 closing, read every 3
  ticks, changes only), and that gate's doors follow it at the gate's speed (a gate coming into view already open is
  drawn open), so they open when Factorio opens them: for a vehicle at speed, a script's `request_to_open`. A gate
  with no state (an old bridge, `/f3d-perf gate_state off`, the mock) is guessed as below, a vehicle's reach then
  growing with its speed: max(4, 0.4 s of its travel). `/f3d-perf gate_state off`: nothing sent (states already
  sent stay until their chunk is dropped). Checked by test_bridge.py and ui_test.gd `_gate_open`; not seen in a
  window.
- `--gate-open=old`: (the guess, for gates without a real state) a gate's door opens while the
  client's own character is within 2.5 tiles of it (its position from main.gd every frame, none while the remote
  view shows another surface) or a friendly vehicle, train or other player's character is within 4 tiles (Factorio's
  activation_distance is 3, but the client isn't sent it). Flying robots don't open gates, as in Factorio. `old`:
  the world's focus stands for the character (so an add-on's camera, which moves the focus to where it looks,
  opened a gate with nobody there) and robots counted, as before. Checked by ui_test.gd `_gate_open`; not seen in
  a window.
- `--inserter-glow=hand|always` (hand): an inserter model's glow (a modeller's lit burner, Vasillo's
  burner-inserter.glb) follows its hand: lit while the arm is drawn turning or reaching and for 30 game ticks
  after (the short waits at its ends), dark while it waits for items or room and wherever no live arm is drawn
  (past the bridge's hands radius the arm rests). Factorio's burner inserter burns fuel only as its hand moves
  (energy_per_movement and energy_per_rotation, no drain); its own burner has no light (light_flicker black)
  and its picture no fire. The bridge sends no `st` for inserters, so their glow counted as always working
  (owner, L4: "the burner stays lit while it's idle"). `always`: lit all the time, as before. Checked by
  inserter_events_test.gd; not seen in a window.
- `--burner-fx=on|off` (on): while a burner inserter whose model has a glowing burner (Vasillo's; the built-in
  packs' have none) is lit by that rule, its glow breathes like coals (0.75 to 1.15 of its level, three slow
  sines in the model shader, `glow_heat`, each inserter out of phase by where it stands), a thin wisp of
  Factorio's light smoke (the smoke sheet, light-smoke's colour) leaves its grille about every 2.5 s within 30
  tiles of the listener, and Factorio's burning-fire loop (base/sound/fire-1.ogg, fire-flame-on-tree's working
  sound) crackles quietly, the nearest 3 at once (scripts/fx/burner_fx.gd). The same in the Model packs window's
  preview: Play animation breathes and smokes, the speaker plays the crackle. The owner's addition: Factorio's
  own burner inserter has none of it. `off`: a steady glow, no smoke or sound, as before.
- `--inserter-arms-trace=<file>`: a JSON line per frame with every drawn hand (unit, x, y, held item),
  the game tick the arms stand for, the belts' drawn tick and the frame's arm cost; with the bridge's
  `/f3d-ih trace [ticks] [radius]` (every hand near the focus each tick into
  server/data/script-output/f3d-ih-trace.jsonl, off by default) `python tools/inserter_check.py --bridge
  f3d-ih-trace.jsonl --client arms.jsonl` reports the hand position error at the tick the arms stand for,
  swing coverage (how much of each true swing the drawn one covers, whether it reaches both ends), the
  arm against the belts' timing at each belt pickup, the drawn hand's item changes against the game's
  held count changes in ticks (every inserter), the bridge's `ie` records' ticks against the true changes
  (the trace writes each event it made), and the cost (client ms a frame, the bridge's `inserters` ms a
  tick, `ih`/`ie` bytes, hand checks a tick). `godot --headless --path client -s
  res://tests/inserter_swing_test.gd` checks the swing model offline against a game-moved hand,
  `res://tests/inserter_events_test.gd` the swing from events and the arms layer fed `ie` messages (a
  third lost, two swapped, an uncertain pick dated back), `res://tests/inserter_arms_replay.gd --
  --trace=<f3d-ih-trace.jsonl> [--events] [--lose=0.18]` the layer against a real trace, fed samples or
  the events the bridge would make of it.

`godot --headless --path client -s res://tests/belt_bs_replay.gd -- --stream=bs.jsonl --truth=rec.json
--drawn-check --every-tick [toggles]` replays a capture (`--belt-capture=bs.jsonl`) with a job a tick as
the client runs them (`--binary`: each part written as a binary frame and read back first, as from a bridge
sending binary; the replay must come out the same) and says, every recorded tick, how far each simulated item is drawn from where the
simulation has it, by cause (`--drawn-explain=N` examples, `--trace=UID` one item). Without a camera every
item is in view; `--view=x,z,w,h` gives the ground view the records are planned for, moved `--view-drift=dx`
tiles east a job, so items park and are planned again as it goes. (A capture made offline with
`tools/bs_offline.py` from a recording serves too.) Experiments: `--oracle-at=TICK` reads every recorded lane
at the first recorded tick at or after TICK (the simulation starts from the game's state there),
`--reads-after=none` then applies no lane reads (the simulation alone), `--persist` says per update
how many of the items the game had then are still exact, within 0.15 tile, on another lane or missing
(with belt_sim.gd, only lanes whose items go on into recorded lanes alone); `--read-probe` (belt_sim.gd)
compares each read with the simulation just before it, by distance and lane kind, and says what reads
took off and whether the game still had it on the next recorded tick. `--replay-bre` answers the job's
own `bre` from the recording two updates on, as the replay always did before; off by default, since a
live capture already holds the bridge's answers to the live client's asks (answering again read lanes
the live client never got: -62,-26 replayed 91.9% visible with it, 87.5% without). `--hold-emu` makes the bridge's `sh` from the recording (a
recorded splitter input whose items at an update are its last read's), `--confirm-emu=split|all` reads such
lanes again (splitters' lanes, or all) as their last read had them at every update: what those would do.
`--every-tick=60 --job-every=30` runs a job every 30 ticks with the updates since the last, the drawn clock 60
ticks behind them, as a live client with `--belt-draw-dump` on a busy base does (its jobs 30-40 ticks apart):
`tools/belt_quirks.py` on such a replay of a live capture (the dump's job lines made into a
`draw.bin.apply.jsonl`) came within a point of the live run's frozen and sliding shares. `--sim-dump-near` (with
`--sim-dump`) writes the simulation's items at its first tick at or after each recorded tick (a recording made
every 30 ticks seldom has the simulation's own ticks, which the plain dump needs); `--fronts-trace=K1,K2,...`
prints each job's `lane_fronts` of those lanes (front, its speed, most items' speed, count).

To measure where the client draws items against a running server: `python tools/belt_path_check.py
layout --rcon-port <port>` builds a test row per belt tier (both curves, a splitter, an underground,
side-loading, packed rows), `record --out truth.json` records every item's place each tick, and
`check truth.json drawn.json [--within x0,y0,x1,y1]` compares where the client drew them with
`-- --belt-path-probe=drawn.json@20` (records 20 s after 10 s, prints belt items' main-thread and worker
time, then quits): by unique id, and by place (each drawn item's distance from the nearest game item
at that tick, p50 and p99, the share drawn with no game item within 0.15 tile, and the share of the
game's items with none drawn within 0.15).

Whether a build's belts look right over the whole view, in one command: `python tools/belt_view_check.py
--worktree <checkout> --ports <udp>,<game>,<rcon> [--at x,y] [--size 64] [--seconds 10] [--settle 40]
[--settle-max 180] [--first-bs 60] [--settings automatic|unlimited] [--hold60 on|off] [--record
updates|tick] [--camera top|free|<yaw,pitch,dist[,ortho]>] [--stand-in] [--reuse-server] [--shots <dir>]
[--json <out>] [--lock <file>] [--keep <dir>] [--replay every-tick|update] [--replay-arg=<arg>] [--tail-wait 30]
[--record-bounds view|square] [--draw-dump on|off] [--client-arg=<arg>] [--client-setting=<key>=<value>]`. It starts that checkout's server on a copy of its `server/saves/zt.zip`
(the mod copied into its server folder first), puts the character at `--at`, runs its windowed client
with `--belt-capture`, a settings file of its own (Hold the game at 60 UPS on, the owner's default;
`--hold60 off` is a diagnostic; `--client-setting` adds a line to its [graphics], as the settings file writes it,
such as `grass_3d="off"`, for a diagnostic) and the camera pinned (`--camera top`: the client's
`--camera=0,85,<size/0.65>,ortho`, straight down, north up, `--size` tiles high, so a branch's and
main's screenshots frame the same ground; `free` leaves the client's own). It counts the client as
joined at the capture's first `bs` line (FAIL after `--first-bs` seconds with none), waits until the
capture's last update has no `ld` (the first load is done) and at least `--settle` seconds have gone
(FAIL "first load didn't finish" after `--settle-max`; the capture is read as the client's file buffer
writes it), records the game's belts over a `--size` square round the character
(`tools/belt_sim/record.py --sample updates`: only the ticks the bridge sends an update on, all the
replay compares; `--record tick` reads every lane every tick as before, which loads the server enough
that Hold 60 UPS slows the bridge's updates), saves the client's view every 10 s, waits (up to `--tail-wait` s) for the capture to reach the
recording's last tick (the client's capture can trail the game by seconds; a capture that still ends
first is compared only as far as its updates go, and the report's head says so), stops everything and
replays the capture through that build's belt_items.gd (`tests/belt_bs_replay.gd --view-dump
--drawn-check --every-tick`: a job a tick with the drawn clock behind the updates, as the client runs
them; `--replay update` runs a job an update at its tick as before, which puts items the records draw
on another lane than the simulation's that the client never shows, so the drawn kinds aren't gated
then; `--replay-arg` passes the drawing's toggles on). The game's belts are recorded over the screenshots'
whole ground (`--record-bounds view`, the default: the pinned camera's bounds, 107 x 60 tiles at --size
60; `square` records the --size square only, as before), and the client runs with `--belt-draw-dump`
(`--draw-dump off` leaves it out): the report's section L scores what the client itself drew, the
records in effect when its drawn clock showed each recorded tick, placed as the shader places them,
against the game's items in those bounds (visible by place, one to one by item name within 0.15 tile;
phantoms; by id; by id on packed lanes, reported only: a packed lane of one kind looks the same whichever
of its items is where, the owner's concession "a lane the game has packed is drawn packed";
`--gate-by-id on` makes it a gate again, under 90% failing), with the client's own pace (jobs with updates and their ms, updates
merged into one job, results drawn late, how far the drawn clock was behind the newest update). PASS
needs live visible >= 97%, live phantoms <= 2% and coverage >= 98% (and packed lanes by id >= 90% with
`--gate-by-id on`); the
replay's score (section 0) is a diagnostic then: replay against game separates the bridge and the
simulation, live against replay the client not keeping up. `--client-arg=<arg>` (repeatable) passes a
switch to the client only (`--client-arg=--belt-draw-coalesce=off` for the client as it was). Reading
every lane on every update tick (`--record updates`) slows the server to 12-30 UPS, which gives the
client several times the wall time a tick it has in play: `--record 60` (every 60th tick, 10 rows) keeps
the game near 60 UPS; the report's head says the game's pace while recording. The report's head gives the run's pace: the updates' `p` (ticks between updates) while
compared and before, when `ld` last showed, the bridge's rate level (/f3d-status) at the recording's
start and end, Hold 60 UPS (and whether that is the default), the client, whether the server was
started or reused, and how the recorder sampled (with `--analyze`, from status.txt, settings.cfg and
run.json beside the stream, or `--status`, `--settings-file`) and how the replay ran. The headline
(0.) is what the owner sees: every game item in the square on a lane that shows (not an underground's
hidden lines 3-4) matched one to one with a simulated item of the same item name on the same lane
within 0.15 tile, at every compared update ("visible"); the simulated items on those lanes with no game
item matched ("phantoms"); "holes", runs of two or more game items in a row along a lane with no match;
the misses with some other simulated item there (another kind, or one already taken); kept on the deep
lanes (4 or more back to an unsimulated feeder, or none) over every update; and what the records draw
on another lane than the simulation's. The view dump gives each item's kind (the game's by the
recording's `names`, the simulation's by the `sl` that set it: the bridge's item ids, matched to names
by the items both have, or the recording's for the `bre` answers the replay makes up). Then, as
diagnostics: lanes simulated by ring round the
character; items kept by how many lanes back the nearest unsimulated feeder is, lane by lane (min(sim,
game) per lane summed, so a lane with too many doesn't make up for a hole on another); items by id
(right, off, other lane, missing, extra) at the first, middle and last update; what the records draw
against the simulation (other lane, standing where the simulation moves); and the headline by id, the
share of every game item in the square whose own id is simulated on its lane within 0.15 tile (beside
it the same by place, any simulated item within 0.15 tile, which a packed lane nearly always has, so it
is not a gate, and how many of the last update's by-place hits are another item; by id, an item on
another lane of a balancer looks the same when another of its kind takes its place, so none of the by-id
numbers is a gate). PASS needs visible >= 97%, phantoms <= 2%, the deep lanes keeping >= 98%, 98% of
lanes simulated, and (every tick) at most 0.05% of the item-frames drawn by the records on another lane
than the simulation's; the exit code is 1 on FAIL. Beside the report,
`lane_map.png` (copied to `--shots` too): the recorded lanes from above at the last update, each
coloured right, right and empty, off, on another lane, hole (missing) or not simulated, over the same
ground and at the same size as the pinned camera's screenshots. `--stand-in` runs `tools/belt_bench.py
--bs --capture` instead of Zenith (no Godot, no screenshots: for bridge-only runs; `--stand-in-cap`,
`--stand-in-near` are its `bfar`). `--reuse-server` keeps the server running on its save copy after the
run and uses it again next time (the character teleported to the new spot), restarting it only when the
worktree's mod changed (copied in again); `--stop-server` stops it. `--main <checkout>` runs the same
spot on a checkout without `bs` for screenshots side by side (with `--reuse-server` on the ports + 10);
`--analyze --stream <bs.jsonl> --truth <rec.json>` reports on a capture already made. A run takes the
server's ~4 GB: `--lock` waits for that file to be free (polled every 5 s) and holds it while a run's
server and client are live (a kept server idles without it). `python tools/test_belt_view_check.py`
tests the report, the lane map, the camera's ground, the lock and record.py's `--sample` on made-up
data.

`tools/belt_sim/record.py --sample` picks the ticks it records: `tick` (every tick, the default, which
sim.py and belt_sim_replay need), `updates` (the ticks the bridge's `bi` job ran, read through a
remote interface, `f3d_rec`, it adds to the bridge mod's Lua state for the recording) or `N[@phase]`
(every N'th tick where tick % N == phase, phase 1 by default: the bridge's `bi` ticks at every rate
level with its default interval of 6). Its rows are appended to the script-output file as they are
made; the recording has the same keys as before plus `sample`, `rows` and, with `updates`,
`bridge_ticks`.

Factorio's belt rules, measured in the running game: `python tools/belt_rules.py --rcon-port <port>
all` (or `lengths speed gap line sideload splitter inserter`) builds small rows on a lab surface of its
own (`zenith-belt-rules`) and records their lanes every tick; docs/BELT-RULES.md has the results.

What items on belts cost the bridge, without the windowed client: `python3 tools/belt_bench.py
--udp-port 34200 --teleport -272,-16 --seconds 40 --json out.json` against a running server (on a
copy of a save: it uses `/c`) connects a stand-in client that asks for belt items as Zenith does
(the High distances by default: `--near 160`, `--cap 6000`, `--units` for Smooth belt items),
`--groups` to say `bg` too, `--runs` to say `br` (straight runs moved by the client). It warms up for
`--warmup` seconds (20 by default) and then records the bridge's per-module times, the game's UPS,
the bytes of each message type, how far moving items reached (`bi` fr: mean, min, max) and
belt_items.lua's counts per update (lanes checked, held, read in full, held as groups, plain lanes
not checked and read, far lanes held, far icon chunks skipped, items read). Its docstring has the
usage.

#### The other probes and debug options

The client's other probes (client/scripts/debug/, each file's header has the details). Each runs
after the `--`, writes its file or prints its lines, and quits when done; run them windowed
against the mock or your own server unless said.

- `--robot-probe=<out.json>[@seconds]`: stands still and records what each frame costs with the
  movers in view (frame, movers' script time, draw calls, GPU); with the mock's `--robots N`.
  `--robot-nodes` draws robots a node each, as before robot_swarm.gd, for comparing.
- `--ao-probe=<out.txt>[@seconds]`: after 20 s (or the seconds given) lists every model MultiMesh
  drawn: instances, shadow casting, visibility, triangles, bounds, per surface whether its baked
  occlusion (COLOR) and second UV map reached it and their mean, the material's `vertex_data` and
  `ao_strength`, and the contact rims' feet (`feet=`); also the sun's shadow settings, the environment's
  SSAO and ao_zoom.gd's reading. It doesn't quit, except with `--ao-probe-shots`: then it saves the
  window with each kind of occlusion off in turn (`<out>-all.png`, `-no-ssao`, `-no-contact`,
  `-no-baked`, `-none`, and `-all-again` for what moves between two pictures anyway), each after the
  picture settles, with the GPU's frame time and SSAO's state in `<out>-shots.txt`, and quits.
  `--ao-probe-ab=<bias>,<normal bias>` saves the window before and after setting the
  sun's shadow biases (`<out>-a.png`, `<out>-b.png`), `--ao-probe-bias=` holds them there, and
  `--ao-probe-own-shadows` makes every model cast its own shadow with the stand-ins hidden.
  `--aa-probe-shots` (with `--ao-probe=`) saves the window under each anti-aliasing choice in turn
  (`<out>-aa-off.png`, `-fxaa`, `-smaa`, `-taa`, `-msaa4`, `-off-again`), the setting held unsaved and
  applied as Settings does, with what the window then has in `<out>-aa.txt`, and quits.
- `--settings-probe=<folder>[@seconds]`: after 25 s (or the seconds given) changes every row of the
  Settings window the way a player does (a dropdown's item picked, a box ticked, a slider let go),
  reads back what each should change in the running game and in the settings file, saves a picture
  before and after the visible ones, goes through each add-on's own settings (did the add-on hear,
  how much the picture moved), and writes `<folder>/report.txt` (PASS / FAIL / NOTE). Each setting is
  put back afterwards. `--settings-probe-restart` then writes a set of non-default values for the next
  start, which `--settings-probe-verify` reads back in the game (`<folder>/verify.txt`). Use a user
  folder and `--settings-file=` of the probe's own: it changes the window's size and mode.
- `--settings-scroll-to=<control name>` (with `--menu=settings:<tab>`): that setting scrolled into
  view, for screenshots (`graphics-antialiasing`); expands a Graphics category's `More` drawer if the
  target setting sits inside it.
- `--graphics-layout=old`: restores the previous single-column Graphics settings window (`General`,
  `Advanced`, `Accessibility`) instead of the 3-column categorized window with per-category `More`
  buttons.
- `--glide-probe=<out.json>[@seconds]`: goes through the bridge's `rate` levels 0 to 3 (30 s each)
  and reports, per kind of mover and for belt items, the speed and how often they stall or jump.
- `--soak-probe=<out.json>[@minutes]`: a long session (30 minutes): walks a square, opens windows,
  builds and mines a wooden chest, and samples memory, objects, frame times, the bridge's gaps and
  resyncs and the server's UPS.
- `--predict-probe=<out.json>[@builds]`: builds a wooden chest beside the character over and over
  and times each click to the game's chest drawn (what scripts/world/predicted.gd hides).
- `--quit-probe=<seconds>`: quits after that long without the exit guard, so a hang on quitting
  stays visible; `python tools/quit_soak.py` starts and quits the client many times with it.
- `--flicker-probe=<folder>[@degrees a frame]`: saves frames while the camera turns slowly;
  `@pan` moves Factorio's view one pixel a frame instead. `python tools/flicker_count.py` (`--pan`)
  counts the pixels that change and change back.
- `--terrain-probe`: every 5 s prints how long chunks waited for their tiles and their ground, and
  how long chunks near the focus were holes.
- `--mod-click-probe=<name>[,<name>...]`: presses mods' buttons in Zenith's copies of their windows
  and logs the windows before and after (no names: lists the buttons); `--mod-click-probe-quit`
  quits after the last.
- With `--stutter-probe`: `--probe-trace=<ticks>` has the bridge log each module's time per tick
  (`f3dtrace` lines in Factorio's log) once the walk starts, asked through the console so
  single-player needs no RCON; `--probe-fine` keeps subtrees over 0.005 ms, not only over 0.1.
- Screenshots of models and animations: `--review-shots=<dir>[@seconds]` (what
  tools/models/review.py starts) with `--review-box=<w>,<d>,<h>`, `--review-aim=<height>`,
  `--review-views=<a,b,...>` and `--review-fly=<path.json>` (a camera flight);
  `--anim-shots=<dir>@<start>,<count>,<step>` saves `count` frames `step` seconds apart
  (`--anim-hud` keeps the HUD), with `--anim-pose=<run|mine|aim|...>` holding the character in one
  animation (also `walk`, `exo`, `back`, `stop`, and in mech armour `hover`, `fly` and `flyloop`:
  take-off, hovering and landing every 4 s), `--anim-rate=<x>` playing it at x times its speed (0.1
  to step through a loop, as each screenshot takes longer than a frame) and `--worm-state=<0|1|2>`
  every worm folded, up or attacking. The mock's `--fly loop|walk` (with `--armor mech-armor`) makes
  the character fly at Factorio's own rates, on a timer or while walking.
- For screenshots and comparing: `--far-merge-from=<tiles>` merges far chunks' buildings from that
  distance (under 40 tiles, up close too); `--rail-from=<x>,<y>` starts the rail planner there once
  rails are held; `--map-surface=<index>` shows that surface on the map after 6 s and
  `--remote-surface=<index>` its world in the remote view; `--update-rate=<0-3>` asks the bridge
  for that `rate` level from the start; `--factorio-locale=<code>` uses that language's names
  instead of Factorio's setting.
- `--from-factorio` is what server/factorio-with-zenith.ps1 passes when Ctrl+F9 in Factorio starts
  Zenith: it comes to the front once joined and minimises Factorio (Settings → Other).

Two more measurements against a running server, without the windowed client (their docstrings
have the usage): `python tools/alt_cost.py` streams the chunks round a spot and measures what
Alt-mode costs the bridge, off and on; `python tools/request_spikes.py` sends the client's requests
one at a time while the bridge traces every tick, and reports the slowest tick round each.

The 0.2.1 hotfix's main-thread fixes (art-src/perf-plans/client-cpu.md), each on by default and
behind a switch that puts back what was there before, for comparing:
- `--terrain-layers=rebuild`: the ground's texture array is made again from every picture loaded
  whenever a new kind of ground's picture is ready, as before (56-114 ms once 35-45 kinds are in).
  On: the array is made with room for 48 layers (grown 16 at a time; 4 when the pictures aren't
  compressed) and a new picture is written into its own layer (`update_layer`).
  An exported game can't compress them: Godot 4.7.2's export templates have no texture compressor
  (etcpak's S3TC and ETC are editor-only, CVTT's BPTC and Betsy only in templates built with their
  options; checked with the release template, every mode `ERR_UNAVAILABLE`), so it no longer asks
  (each try logged `"_image_compress_bc_func" is null`) and keeps each picture as RGBA8, the format
  Godot's renderer turned the old RGB8 into on every upload (2.8 ms a picture on the main thread). The
  cost: 11.2 MB a kind of ground on the GPU and in RAM, against 1.4 MB compressed; a base's 35-45
  kinds about 0.5 GB of each, against 70 and 60 MB. The log says so once ("Terrain textures: the
  ground's pictures are kept uncompressed").
- `--lod-pass=every-frame`: models' levels of detail are looked at in every chunk every frame (past
  1,700 chunks the 12 rings round the focus and 1,500 more a frame), as before. On: the two rings
  round the camera every frame, each band of rings further out only once the camera moved 3% of the
  band's distance (or the zoom, the window or the levels changed), within the frame budget's `lods`
  slice; standing still, nothing. Chunks shown again behind the camera switch without a cross-fade.
- `--lod-slice=off`: disables per-chunk ring slicing and the per-frame MultiMesh switch cap
  (`LOD_SWITCH_CAP`) in the banded LOD pass, switching a whole ring in one frame as before.
- `--lod-cpu-copy=off`: reads `MultiMesh.buffer` back from the RenderingServer on LOD cross-fades
  instead of building the fade copy from CPU-cached instance data.
- `--lod-mesh-touch=off`: skips re-writing instance 0's transform after a LOD `MultiMesh.mesh`
  swap (the workaround for Godot 4.7 Forward+ zeroing MultiMesh instances on later per-instance
  updates under FSR2/TAA motion vectors).
- `--textured-lod=legacy`: restores the fixed `[64, 32]` px switch sizes and `[0.3, 0.15]`
  triangle floors for textured models instead of the triangle-density ladder and 7% third tier on
  dense models.
- `--heavy-lods=off`: old level thresholds for heavy building models. On (default): a model's levels switch in sooner (smaller on screen) by sqrt(triangles / 1000), at most 3.5x (assembler ~3.5x, medium pole ~1.6x, models under 1000 triangles unchanged), and dense textured models of 8000+ triangles get a fourth level at 3% of the triangles (`model_lods.gd` `heavy_scale`, `HEAVY_*`).
- `--tree-lod=off`: disables card-level view LODs on trees, keeping full leaf cards at every distance as before.
- `--far-trees=off`: keeps trees and plants as MultiMeshes in far chunks instead of merging their trunks and crowns.
- `--hover-rate=off`: the entity info panel (the hover panel) is rebuilt for every new entity under the cursor while the character runs too, as before. On (default): while the character (or its vehicle) moves faster than 3 tiles a second, at most every 100 ms (`entity_info.gd RUN_REBUILD_MSEC`), the last entity shown meanwhile (each rebuild was 2-6 ms as entities slid under a still cursor).
- `--free-later=off`: nodes and old meshes the world lets go of (a far chunk's merged mesh when it comes near or is merged again, a chunk's ground, decoratives, belt lane icons, contact shading, cliff walls, Distant Horizon's sections) freed with `queue_free` all in the frame they went, as before. On (default): hidden at once and freed a slice a frame (`free_later.gd`, 1 ms, 2 ms with over 512 waiting), from world.gd's `_process` (the owner's spike log had 20-78 ms of "deferred+frees" in the frames far chunks merged and chunks streamed).
- `--free-later-leaves=off`: a node waiting in `free_later.gd` freed whole with its children in one `free()`, its meshes with it (frame-spikes2's way: one big chunk's free could hold a frame for 20 ms past the 1 ms slice). On (default): the node taken apart from its deepest last child, one leaf a free, each mesh instance's mesh or MultiMesh let go in a step of its own, the clock read after each.
- `--disk-flush-sliced=off`: the chunk disk cache's flush (every 10 s) copies every dirty region's chunks (up to 256 a region) in the frame it starts, as before. On (default): copied 1 ms a frame, then written on a worker as before.
- `--disk-promote-sliced=off`: a region read from the disk cache promotes all its waiting chunks into the memory cache in that frame, as before. On (default): 1 ms a frame (at least one chunk).
- `--belt-lanes-start-sliced=off`: belt lanes' job takes every waiting chunk (each chunk's curved belts read on the main thread), as before. On (default): what fits 1 ms (at least one chunk), the rest the next job.
- `--far-installs=N`: at most N finished far-chunk merges put in a frame (default 1; `0` no cap, as before, within the frame budget's `far_install` slice).
- `--shadow-small=old`: every model in a chunk casts into the sun's shadow map at every shadow tier, as before. On (default): models whose top is under 0.08 tile cast nothing anywhere, and under 0.55 tile nothing in chunks past the ring round the character (`SHADOWS_FAR`); belts are left casting (`chunk_view.gd` `too_low_to_cast`). Fewer draw calls in the shadow pass.
- `--far-merge-sooner=<f>`: far chunks merge (and unpack) this many times sooner than before, by screen size or by distance from the character (default 1.3: the character-anchored merge from about 108 tiles instead of 140, unpacked inside about 86 instead of 112; `1` the distances as before; 0.5-3).
- `--decor-nodes=<n>`: at most about n new decorative MultiMeshes put in a frame, a whole chunk at a time, the first chunk of a frame always (default 96; `0` no cap, only the time slice, as before).
- `--alt-marks-sliced=off`: Alt-mode's arrows (`alt_arrows.gd`) and quality marks (`quality_marks.gd`) work out every changed chunk in the frame Alt-mode comes on, as before (58 + 38 ms in one frame on the owner's base). On (default): 2 ms (arrows, nearest chunks first) and 1.5 ms (quality marks) a frame while Alt-mode is on, and 0.3 ms a frame each while it is off, so turning it on finds them ready; arrows of far chunks may come a few frames late.
- `--ground-walk=old`: when the hills' range grows (a new field from Terrain Elevation), the whole scene tree searched and every drawn node given room in that frame, as before (39 ms in one frame on the owner's base, and a long draw after it). On (default): the nodes known since the hills came (found once, then each one added) walked 3 ms a frame; nodes not reached yet may be culled at the screen's edge for a few frames.
- `--render-reads=old` (and the setting Graphics > "Render on a separate thread", on by default, off = the main thread draws as before; needs a restart): with the separate render thread every read from the RenderingServer waits for it (15 -> 76 ms frames). By default item models keep their surfaces' arrays and pictures on the CPU (`f3d_arrays`, `f3d_cpu_image`: no `surface_get_arrays`, `ArrayMesh.duplicate()` or `get_image()` readbacks), icons keep their picture for Alt-mode's icons on the card, a LOD switch with no CPU copy switches without the cross-fade instead of reading `MultiMesh.buffer` back, and the debug overlay, debug menu and Settings' Recommend read the renderer's numbers on the render thread (`render_stats.gd`, a frame or two old); quitting waits for belt stand-in and cliff-wall workers and one drawn frame, and `exit_guard.gd` ends a quit stuck past 8 s. `--render-reads=old` reads the renderer directly again, as before.
- `--item-models-later=off`: an item model (items on belts, the ground, in hands) is read on the main thread the first time it is asked for, as before. On (default): a pack's `.glb`/`.gltf` item model not read yet is read on a worker thread (GLTFDocument, as buildings' models are; not ResourceLoader's threaded loads, which once deadlocked at start), a new item kind shows once the read is in, usually a frame or a few later (item_cards.gd already held a kind back so while its icon was read; the icon card is not shown in between); Zenith's own imported `res://` scenes are still read on the main thread; `mesh_for` never waits for a worker (it reads at once and drops the worker's result).
- `--icons-later=off`: the entity info panel (the hover panel) reads an icon that isn't cached yet at once,
  on the main thread, as before. On (`Kit.icon_into`): read on a worker thread and filled in a frame or
  a few later, so the camera sweeping new kinds under a still cursor never waits for a file (13-15 ms
  frames on a cold disk).
- `--decor-sheet=off`: keeps flat decoratives as separate per-kind MultiMeshInstance3Ds per chunk instead of baking them into one chunk sheet (`decor_sheet_baker.gd`).
- `--decor-sheet-compress=on`: S3TC block-compresses baked decorative chunk sheets in editor builds (off by default to avoid `Image.compress` stalling `WorkerThreadPool`; export builds always skip compression).
- `--build-parts=each`: a chunk is built again on each `ents` part of its snapshot, as before. On:
  once its last part is in (or 0.5 s after the snapshot started, a part lost meanwhile).
- `--build-apply-deadline=off`: a chunk's build fills all its MultiMeshes in one go once its records
  are read, as before. On: it stops at the frame's deadline between models too.
- `--kept-replay=inline`: a kept chunk (`same`) is replayed inside that one message, as before. On:
  its kept messages go to the front of Bridge's queue and are handled within the message slice.
- `--frame-budget-measure=godot`: the frame budget's pool is worked out from Godot's
  `Performance.TIME_PROCESS`, as before. That is the slowest whole process step of the last second,
  the renderer's sync and draw included (Godot 4.7.2's main.cpp), so the pool sat at its 3 ms floor
  on a big base. On: the frame's other scripts are measured from the first sliced system's ask to
  the last script of the frame (a node world.gd adds at the last process priority). The stutter
  probe's frames carry both (`fb_other` in µs, `time_process` in ms).

- `--pipeline-warm=off`: a model is drawn as soon as it is made, as before, and Godot compiles its
  pipelines inside the first frame that draws it (0.2-0.9 s frames on a cold shader cache). On (not
  headless; `--pipeline-warm=on` forces it there): a model whose surfaces bring a shader and vertex
  format not met yet first stands far under the world as a one-instance MultiMesh, out of every view,
  where Godot builds its surface cache and compiles its pipelines on worker threads, and chunks leave
  it out for 300 ms and 3 frames meanwhile (`--pipeline-warm=<msec>` sets the 300), as they do while
  a model is read. Its levels of detail and shadow stand-in are warmed the same way once made.
- `--pipe-warm-extra=off`: the hover marks', Alt-mode's card shader's and the post effects' (SSAO, SSIL, glow, grade, fog, shadowed sun) pipelines are built when first drawn, as before (20-100 ms frames on a click, a hover or a setting change). On (default, not headless): a hidden 64x64 viewport draws them a few frames while the client starts (render_warm.gd).
  Each save's models are kept by name (user://seen-models/<save id>.json) and asked for at the
  welcome. The probe's frames carry Godot's five pipeline counters apart (`pl_draw`: the ones a draw
  waited for; `pl_surface`, `pl_spec`, `pl_mesh`, `pl_canvas`) and `warming`.
- `--join-warm=off`: the join's loading screen goes once 9 chunks are loaded (or 6 s), as before. On:
  it then stays, "Preparing models and shaders", while the chunks within two of the character aren't
  built with every model or pipelines are compiling, at most 25 s after the world is ready; models are
  read on all but two of the processor's threads meanwhile (3 in play).

- `--decode-thread=off`: map charts' pictures (`chart`) and chunks' tiles (`chunk`) are decoded on the
  main thread when handled, as before. On: on the bridge's parsing thread as each message is read
  (client/scripts/net/message_decode.gd); a message with fields of the wrong kind is left as it came.
- `--binary-messages=off`: the hello leaves `bin` out and the bridge sends everything as JSON text, as before.
  On (the default): the bridge sends binary frames (docs/PROTOCOL.md, "Binary frames"; wire_decode.gd reads
  them), the movers (`mv`) written with `string.pack` instead of as text (about 40 ns a number in the game
  against 290-670), and from wire version 2 the belts (`bs`, each lane key as unit number and line) and far lanes
  (`bfar`) too, their lists kept as numbers rather than text; everything else as its JSON text inside a frame.
  From wire version 3 the chunk snapshots (`chunk` tiles, `ents` records with their extras as a JSON tail), the
  machine states (`st`) and the inserter hands (`ih`) too; the snapshot jobs then keep numbers, not text. A
  client of an older version gets the newer kinds as text, and a hello that lowers it while binary chunk
  snapshots wait starts the stream over. `--belt-capture` writes a binary `bs` part as its JSON,
  so captures and the tools reading them are the same either way. The map setting **Binary messages to
  Zenith** (`f3d-binary-messages`, on) turns it off from the bridge's side, from the client's next hello (a
  second). `/f3d-selftest` says which a client gets; `tools/live_check.py --binary` checks a live server with it.
- `--robot-sim=on|off` (on): simulate worker robot flight on the client and GPU (`rb`, wire version 4, smoothly crossing Factorio 2.0/2.1's 20-tick position-limbo steps and skipping per-tick `mv` + `rc` polling); `--robot-sim=off` or `/f3d-perf robot_sim off` puts `logistic-robot` and `construction-robot` back on `mv` + `rc`.

Not behind a switch: the graphics list's last part is merged and written to the cache on a worker
thread, and a new list's clutter is built again a slice a frame nearest the focus first (with the
chunks whose ground rules changed); the hover panel builds its JSON key only when the record, its
`extra`, health, states or the `hinfo` answer changed; the stutter probe's chunk latency looks only
at chunks that arrived (and the strips the square gained or lost), and Input's parts are timed under
it (`w_in_pick`, `w_in_mover`, `w_in_panel`, `w_in_highlights`).

### Graphics savings in 0.2.1 and their switches

The 0.2.1 hotfix's GPU changes (art-src/perf-plans/graphics.md, items 2, 3, 5, 8, 9, 10 and 11). Each
one that changes what is drawn has a switch that puts it back as 0.2.0 had it, for comparing in two
runs side by side; the stutter probe's `relief off` and `lod lines <n>` variants price two of them
in one running client.

- **Empty decorative pixels** (shaders/decorative_flat.gdshader): a flat decorative's pixel with no
  alpha is discarded right after the atlas read, before the mask's read and the lighting. Nothing
  changes on screen; no switch.
- **Levels of detail on at most 1440 lines** (model_lods.gd `max_lines`): the models' levels
  (world.gd), Godot's own levels (the shadow stand-ins, creatures: Viewport.mesh_lod_threshold is
  scaled by the window's lines over it, again when the window changes size) and SSAO's fade
  (ao_zoom.gd) count a picture taller than 1440 lines (Level of detail High and Medium; 1080 on Low)
  as that tall, so 4K switches where 1440p does. The contact rims stay in real pixels.
  `--lod-lines=<n>` counts on n lines whatever the setting; `--lod-lines=0` counts every real line,
  as 0.2.0. The stutter probe's `lod lines 0` (or any n) does the same for one variant.
- **Tighter Low LODs and custom LOD falloff distance** (Settings → Graphics → Performance → More
  `LOD falloff distance`, `graphics/lod_distance`, default `0` = Auto): `Low` LOD now starts falling
  off at roughly half the previous Low distances (`--lod-low=old` restores the prior Low values).
  Setting `LOD falloff distance` (`4`–`160` tiles (step `4`); `0` follows Level of detail) scales models,
  shadow stand-ins, belt stand-ins, 3D items on belts, merged far chunks, and detailed lights
  together from that falloff distance.
- **Alpha Blend materials that can't be see-through** (model_textures.gd `solid_blend`): a BLEND
  material whose base colour alpha is 1, whose picture has no alpha channel or only opaque pixels,
  and that doesn't glow, loads as a solid material. Vasillo's belt surface is one: the top of every
  belt, splitter and underground leaves the transparent pass and gets the depth pre-pass, SSAO and
  contact shading. `--opaque-blend=off` keeps every BLEND material see-through.
- **Belt surfaces with see-through pictures are cut out, not blended** (model_textures.gd `clip_belt`):
  a BLEND belt surface (belt_return.gd `is_surface`) whose picture has transparent pixels (Vasillo's new
  belts: notched plate corners) loads as Alpha Clip at 0.5 and is drawn with factorio_material_clip.
  Blended, it wrote no depth and the return run, drawn in the same draw, painted its backward chevrons
  over the top ("chevrons pointing both ways"). `--belt-surface-blend=on` keeps it blended, as before
  0.2.2. Also, the return's triangles now come first in that draw (belt_return.gd `joined`), so even a
  blended surface draws its top run last; `--belt-return-first=off` puts them after, as before.
- **Emission as the glTF file says** (model_textures.gd `emission_strict`): a material glows only by its
  `emissiveFactor` (absent means none, glTF's default) and only when its emission picture isn't black on
  every pixel. Godot's reader turned emission on, white, for any emission picture, and Zenith drew such a
  material as lighting up at work, a see-through one as a plume that is gone at rest: Vasillo's export
  wires a black emission picture with no factor into 30 see-through materials, so his new pipes, ores,
  plates and drill bodies were invisible unless working ("none of the new models show up in the
  viewer"). The glow that is drawn is the picture x the factor x the strength
  (KHR_materials_emissive_strength). `--emission-strict=off` reads them as before 0.2.2.
- **A modeller's glow dims only itself at rest** (model_library.gd `glow_keeps_albedo`): a glowing
  material from a modeller's pack without an emission picture (Vasillo's drill's `Light`: a factor, no
  picture) goes dark at rest by its glow alone; its base colour is the same idle and working (Zenith's
  own fire boxes and lamps still dim theirs to 30%, as Factorio's do; a material with its own emission
  picture already didn't). `--idle-dims-glow-paint=on` dims it as before 0.2.2.
- **Nearly opaque Alpha Blend is cut out** (model_textures.gd `clip_blend`, the general case of
  `clip_belt`): a modeller's BLEND material whose base colour alpha is 1 and whose picture is opaque on
  95% or more of its pixels (Vasillo's drill: 0.1-0.3% of pixels a little see-through) loads as Alpha
  Clip at 0.5, so its parts sort and get the depth pre-pass; real glass (pipe-alt's `Glass`, 0.6 alpha
  everywhere) stays blended, and built-in packs are unchanged. `--blend-clip=off` keeps it blended.
- **Ore as scattered rocks** (model_library.gd `ore_rocks`, chunk_view.gd `_scatter_ore`): a pack with numbered
  ore models (`iron-ore-1.glb`, `-2`, ..., `copper-ore-N`, `coal-N`, `stone-N`, `uranium-ore-N`) or a plain
  `<ore>.glb` under 0.6 tiles on its larger side draws each ore tile as rocks by Factorio's eight richness stages
  (`ORE_STAGES`: from 150, 400, 1300, 2900, 5500, 9500 and 15000 ore; uranium's own 100, 270, 870, 1930, 3670, 6330,
  10000): 3, 5, 6, 7, 8, 10, 12 or 14 rocks, sized 1.1, 1.2, 1.35, 1.5, 1.6, 1.7, 1.8 or 1.9 times their 0.8-1.2
  jitter, poorest to richest, so they hide about as much ground as Factorio's ore pictures (22% to 96%). From a hash
  of the tile, in the chunk's MultiMesh per rock model, filled rank by rank: a far
  chunk (far_chunks.gd) shows every tile's first rock by the MultiMeshes' visible count, without a build.
  `--ore-scatter=auto` (default) as said; `--ore-scatter=on` scatters any plain ore model too, and a pack whose
  pack.json says `"ore_scatter": false`; `--ore-scatter=off`: one model a tile, as before 0.2.2.
  `--ore-look=old`: a "pbr" pack's ore rocks drawn as any model (Burley diffuse, the file's occlusion picture on ambient)
  instead of as belt ore is (Lambert, no occlusion: factorio_material_ore.gdshader).
  `--ore-density=classic`: 0.2.2's first scattering, 2, 4 or 6 rocks (under 400, from 400, from 2900; uranium 270
  and 1930) at their 0.8-1.2 size. A 60 x 60 patch draws 24,212 rocks near (classic 15,416; far 3,600 either way).
- **Window pipes** (model_library.gd `pipe_window`, pipe_insides.gd, fluids_power.gd, world.gd `extra.pw`): a
  straight pipe where its floored x plus floored y is even is drawn with `pipe-straight-vertical-window` /
  `-horizontal-window` when the pack drawing its straight has that model (Factorio's window on every second pipe).
  Hollow single-sided window models get inward-facing back faces on load so the ground never shows through the glass
  (`--pipe-insides=off` skips that), and the fluid inside is drawn behind the glass (`--pipe-fluids=off` hides it).
- **Storage tank level window**: off by default (owner); `--tank-window=on` draws it again (`fluids_power.gd` `tank_windows`).
- **Menu frame rate**: the front end runs at 60 FPS at most (lower if the FPS limit is lower); `--menu-fps=<n>` changes it, `--menu-fps=0` leaves it uncapped as before (`settings.gd` `MENU_FPS`, `in_menu`).
- **Trains and signals on elevated rails** (`world.gd` `rail_height`, `movers.gd` `_ride_rails`, `model_library.gd` `placed`): rolling stock rides at the elevated track's height (4.45 tiles, the Placeholders models' deck), climbs a ramp as its model does and pitches with the slope (height under its front and back bogies); rails found by their track's reach from a per-chunk index, not their selection boxes; signals on elevated rails (the bridge's `extra.el`, `rail_layer`) stand at the track's height. `--elevated-trains=old`: as before (3 tiles, rails found by selection boxes, no pitch, signals on the ground).
  `--pipe-windows=off`: none of the window models, insides or pipe fluids.
- **A mining drill's fluid part** (model_library.gd `wet_model`, chunk_view.gd `_add_wet`): `<drill>-wet.glb`
  drawn over a drill whose record's `fa` has bit 1 (the bridge sends it for a drill over a resource that needs
  fluid), if the drill's pack has it; a chunk is drawn again when that bit changes. `--drill-wet=off`: never.
- **Pipe covers** (pipe_covers.gd, world.gd `_cover`, chunk_view.gd `_add_covers`): Factorio's `pipe_covers`. Each
  fluid connection of a machine (the prototype's `eprops` fb) with nothing connected to it (no pipe whose `pc`
  reaches back, no pipe to ground facing it, no machine with a connection back) gets a cover from the pack that
  draws the machine: its `pipe-cover.glb`, else the cap of its pipe kit (`pipe-ending-down` less
  `pipe-straight-vertical`: Vasillo's pipe-cap, so his wet drill's open pipe ends are closed). A drill's show while
  it takes fluid (`fa` bit 1), a crafting machine's those its recipe uses, the rest all of theirs. Worked out again
  when a pipe or machine is built or removed next to it. Packs with neither model (the built-in ones) draw none.
  `--pipe-covers=off`: none.
- **Contact shading's patch under big machines** (contact_shade.gd `PATCH_EDGE`, `collect`'s footprint): the
  faint patch under drills, labs, radars, centrifuges, pumpjacks, refineries and reactors has its feet clamped
  to the building's tiles and fades out 0.1 tiles past them, its ring as wide as the rim's (0.27). It used to
  fade over 0.5 tiles past a foot that on a drill reaches the tile edge: a dark band all round every drill
  (31-35% dark at the tile edge, 14-16% 0.1 tiles out, 7% at 0.2; now 10-28%, 1-5%, 0%), where Factorio's
  drill has none past its body. `--contact-patch=wide`: as before.
  The clamp moves the patch alone: the rim stays round the model's real feet, so a machine whose base overhangs
  its tiles (Wube3DP's electric drill by 0.11 tiles, Vasillo's by 0.08, the placeholder burner drills) keeps its
  rim on that side instead of having it pushed under the model (such a foot gets a rim ring and a patch ring).
  `--contact-rim=clamped`: one clamped ring a foot, as the drill-border fix first had it.
  Under the foot the rim and patch fade out over 0.05 tiles (contact_shade.gd `INNER_FADE`, the shader's
  `inner_fade`), gone before the ring's hole. They were drawn at full darkness from the foot's box in to the hole
  and cut off there: hidden under a solid base, but where a body doesn't fill its feet's box (Wube3DP's electric
  drill between its rear legs, 0.38 tiles deep) a dark band with a sharp inner edge lay on the ground past the body.
  `--contact-inner=hard`: as before.
- **Contact shading shaped by each model** (contact_shade.gd `mask_of`, `commit_mask`; the shader's mask mode): the
  rings follow boxes, and a box was dark where the model has no part (Vasillo's electric drill: dark patches beside
  its body between the legs; the burner drill: a dark oval off one leg; an underground belt and a curve: dark ground
  under the hood and outside the curve). Each model's contact map is now made from its own mesh once, on the loader's
  worker thread: its triangles (moving parts in their rest pose) within 0.25 tiles of its lowest vertex, seen from
  above, the lower the darker, turned into the distance to that contact over a 64 x 64 mask (its contact plus 0.3
  tiles). The masks share one R8 atlas (16 a row, grown as needed, 4 KB each; the same mask twice shares a slot) and
  the rings' shader, profile, strengths, speckle and neighbour halving; one quad per building, turned and mirrored
  as it is, on a MultiMesh under the chunk's ring node (`ContactMasks`). Belts, pipes and walls (by file name) also
  get a joined variant, carried straight to the half-tile line their contact reaches and cut there, so a run's
  tiles meet in one rim with no bead at the joints (a run's open end has no rim round it). Models with no mask keep
  the rings: a mod's picture card, files named as rails, trees, rocks, ores, vehicles and the like (no shading
  anyway), and a full atlas (4096 masks). Cost, all 636 built-in and Vasillo's models: 480 masks in 6.5 s of loader
  time (about 13 ms each, a third of their load), 2.9 MB of atlas. `--contact-shape=box`: the rings for all, as
  before, and no masks made.
- **Contact shading under items** (item_cards.gd `contact`, `_with_contact`; shaders/item_contact.gdshader): items
  on belts and on the ground get the buildings' soft dark rim on what is under them (the belt's surface between
  its rails, or the ground), round their look's footprint (an icon card's middle 60%), as strong as the rim
  (`rim_dark` times 0.8) and as wide (`rim_falloff`): the debug menu's Contact strength and rim width move both,
  Settings > Graphics > Contact shading shows or hides both, and it fades out at far zoom as they do. A kind's
  mesh is a copy of its look with one more surface, a box round the footprint from 0.2 tiles under the item's base
  to just over it, drawn by the kind's own MultiMesh in the alpha pass as a decal: it reads the opaque scene's
  depth (already copied each frame for the cloud shadows) and darkens what lies below the base outside the
  footprint, so it follows the items on the GPU and costs one instanced draw a kind and the box's pixels, nothing
  a frame on the CPU; a pile's copies and inserters' hands have none. `--belt-item-contact=off`: no box (as
  before); `=flip`: on and off every 10 s, for `--item-bench`, which says the share of frames they were on.
- **Variants of every model, item model and icon** (model_packs.gd `variant_base`, `variants_in`; model_library.gd
  `pick_variant`): `<name>-1`, `-2`, ... and `<name>` are variants of `<name>` (not a numbered Factorio prototype:
  `assembling-machine-2`), one entry in the Model packs window; each placed entity and ground item draws one picked
  by a hash of its position (`extra.zv`, set in world.gd), an icon one picked by its name. A pack.json's
  `"aliases": {"coal-ore": "coal"}` reads its files under Factorio's names. Ores as before (scattered rocks).
  Items on belts draw theirs too (`items/stone-1..3`): a simulated item the one who it is picks, its number along
  its run as for its turn (item_cards.gd `lattice_variant`), kept while it travels and across re-reads; a packed
  lane's slots the same in the shader (`belt_lattice_variant`: a lattice kind per variant over the same records,
  each drawing its variant's slots); far lanes' icons by their place; an inserter's hand one per thing it takes.
  `--model-variants=off`: always the plain model (the window still groups them), items everywhere included.
- **Which packs have an ore** (model_packs.gd `provides`): a pack with only an ore's numbered rocks
  (`iron-ore-1`...), or its `-rich`/`-sparse` stages, provides that ore: listed on the ore's card in the
  Model packs window, drawing it when it is the order's first with it (model_library.gd
  `ore_scatter_names`) or chosen for it, the card tagged in use then. One rule for all three.
- **A modeller's item pictures** (item_models.gd `material_for`): an item model whose surfaces share a
  base-colour picture is drawn with it, by one material per item model kept with its mesh and shared by
  every instance (item_cards.gd's MultiMeshes on belts, the ground and in hands; belt_lanes.gd's far
  belts; the Model packs preview), the picture times the vertex colours, without the 0.75 exposure the
  icon-coloured items get. Built-in items (vertex colours, no picture) keep the one shared material.
  `--item-pictures=off`: pictures left out, every item model by its colours alone (as before 0.2.2).
- **A modeller's item drawn with its file's own materials** (item_models.gd `own_look`, `dressed`): an item
  model whose materials have more than one shared picture draws (pictures that differ between its
  surfaces or on only some, glow, see-through parts, or roughness, metal or normal pictures in a pack that
  isn't "pbr") keeps them, one material per surface, as
  its buildings do: base colour and its picture, roughness and metal with their picture, normal map,
  emission and alpha (item_own.gdshader for items on the ground, near belts and in hands; far belts'
  belt_lane_model.gdshader `own`; the Model packs preview with the file's materials), whatever the pack's
  shading and with or without pack.json, its pictures made ready as a building's (model_textures.gd
  `prepare`). See-through (glTF Alpha Blend) parts are blended at the file's alpha in the transparent pass, as
  buildings' glass is (item_own_blend.gdshader, belt_lane_model_blend.gdshader; the item's other parts stay in the
  opaque MultiMesh pass; with a depth pre-pass, as Godot draws glTF's Alpha Blend in the preview, so a one-surface
  flask's opaque pixels still write depth and cast shadow and only its glass blends; several see-through parts in one item blend smallest first,
  so a liquid shows inside its glass); `--item-glass=dither` dithers them in the opaque pass instead (stippled,
  more see-through), as the first 0.2.2 drawing did. Only one picture shared by
  every surface was drawn before, so a model of several materials (Vasillo's science pack) came out plain
  grey. `--item-materials=old`: as before.
- **Items already drawn follow the packs** (item_models.gd `generation`): when an item's model file changes
  with the packs' order, switches or choices, the item kinds drawn with the old one (item_cards.gd: on the
  ground, near belts, in hands; belt_lanes.gd's far belts) are made again with the new file. Checked only
  when the packs change (an int compare a frame otherwise). `--item-kinds-follow=off`: they keep the model
  they were first drawn with until a restart or a surface change (as before 0.2.2).
- **Baked animation played as the file says** (model_skin.gd, factorio_material.gdshaderinc `anim_baked`): a
  modeller's action is sampled at its own key rate (the closest two keys of any channel), 30 to 60 frames a second,
  up to 4096 frames (Vasillo's 35 s electric drill: 2101 frames at 60 a second, its bones' texture 2.7 MB against
  0.66 MB, the same again kept on the CPU for its bounds; it bakes in about 1.9 s on a worker instead of 0.4).
  Between two frames a bone whose axes turn more than about 30 degrees is shown at the nearer frame instead of
  mixing the two matrices, which shrank it (his fans to 57% of their width, the bit to 22%); slower bones are
  mixed as before. Not behind the switch, a plain error: a bone with uneven scale is posed rotate x scale as glTF
  says (the burner drill's counterweight arm sat 7 cm off). `--baked-anim=old`: 30 frames a second, at most 512,
  always mixed, as before 0.2.2.
- **Pictures shared between models** (model_textures.gd): a picture is made into a texture once, found
  by an MD5 of its bytes in the .glb (and failing that a hash of its decoded pixels), whatever model
  brings it; Vasillo's 39 models carry 188 textures of 48 pictures. A picture drawn crisp (NEAREST) is
  kept apart from its smooth use. `--share-textures=off`: every model its own copies.
- **Belt items' shadows** (item_cards.gd `BELT_LAYER`, avatar.gd, sun_shadows.gd): items on belts are
  on render layer 19, which the character's lantern and flashlight leave out of their shadow casters
  (the sun still has them); they cast within 0 / 30 / 45 / 60 tiles of the camera on Shadows Low /
  Medium / High / Ultra (was 30 / 45 / 60 / 80). `--item-light-shadows=on` puts them back in the
  lights' shadows.
- **The leaf cut's pollution hash** (factorio_material.gdshaderinc `leaf_cut`): only where pollution has
  made leaves fall. No switch.
- **The ground's relief** (terrain.gdshader): the three extra reads of the tile picture for its bumps
  and crevices fade out from 1.5 to 3 texels a pixel, where the mipmaps have already flattened them,
  and aren't made past that; off altogether at Level of detail Low. `--relief-fade=off` keeps them at
  every distance, `--ground-relief=on|off` forces them whatever the setting; the probe's `relief off`.
- **Matte ground and plants** (terrain_textures.gd `SURFACES`, terrain.gdshader, decorative_grass.gdshaderinc): each
  ground tile family has its own roughness and specular (concrete 0.9 / 0.1, refined 0.88 / 0.12, stone path 0.92 /
  0.08, landfill and natural ground 0.95 / 0.05, platform foundations and ice a little smoother), carried per tile in
  the mesh's CUSTOM1.w; never metal. Grass, carpet clumps and flat decoratives: specular 0.05, roughness 1. Godot's
  Fresnel brings most of a low sun's highlight back at grazing angles unless the specular is tiny, so with the sun low
  behind the scene paving glared pale and back-lit grass turned white. `--ground-rough=off` gives the ground 0.2.2's
  values (natural 1.0 / 0.15, floors 0.8 / 0.3), `--grass-backlight=old` the plants' (specular 0.5, carpet roughness
Trees (and rocks with grain): `--tree-sheen=old` (also `--grass-backlight=old`) keeps the 0.2.2 specular 0.5-0.2; default is matte (0.05, roughness 1). `--night-vision-fx=old` keeps night vision's first look (ambient lift 1.4, edge 0.42).
  0.9). The debug menu's Lighting tab: "Ground roughness" adds to every tile's.
- **3D grass and flat decoratives, GPU-lean shaders** (Stage 1 of the terrain/decorative optimisation): 3D tufts and
  bushes (`decorative_grass.gdshader`) are cut out with alpha to coverage in the opaque pass like the carpet instead of
  blended in the transparent pass; all four plant shaders (tufts, carpet, flat pictures, chunk sheets) drop specular
  (`specular_disabled`, it was 0.05 anyway); flat pictures and sheets cull back faces (their quads face up); the
  carpet checks the mask once per clump (not five times) and stands fewer clumps (`dense_frac` 0.30 / `sparse_frac`
  0.20, were 0.45 / 0.35). `--grass-opt=old` draws the previous shaders (`decorative_*_old.gdshader`: blended tufts,
  the old carpet density, flat pictures with specular); `--grass-backlight=old` implies them too.
- **Ground: interior/coast shader split** (Stage 2 of the terrain/decorative optimisation): the ground is two
  surfaces and two shaders over one shared body (`terrain_common.gdshaderinc`). `terrain.gdshader` draws the
  interior (about 98% of the ground) with no `discard`, so hardware early depth and a cheaper depth pre-pass work;
  the coast's quads (a land tile with water beside it, the wet shelf under it, the shelf over the water:
  `TerrainMesher.shore`) are `terrain_shore.gdshader`, which keeps the ragged cut. Textured tiles also work out
  less noise (one octave of broad variation, one bump gradient, two octaves of transition edge). `Visuals.set_terrain_param()`
  sets a parameter on both ground materials. `--terrain-opt=old` brings back one surface and `terrain_old.gdshader`
  (the original) for all of the ground.
- **Decorative sheets drawn by the ground** (Stage 3 of the terrain/decorative optimisation): a chunk's baked flat
  decoratives (`decor_sheet_baker.gd`, the chunk's `FlatSheet` blended over the ground) are read by the ground's own
  shader instead (`terrain_common.gdshaderinc`: the chunk's sheet in a copy of the ground's material set on its
  terrain surfaces, `ChunkView.set_decor_sheet()`), so no blended pass draws them. They follow the Decoratives layer
  (`f3d_decor_composite_on`, off with Settings > Graphics > Decoratives off), its range and the behind-the-camera
  cull. A chunk whose ground is the far simple one, or not built yet, keeps its `FlatSheet` until it can.
  `--decor-composite=off` draws every `FlatSheet` as before (also with `--grass-opt=old`, `--grass-backlight=old` and
  `--terrain-opt=old`).
- **Far merging no further than 192 tiles** (far_chunks.gd `MERGE_CAP`): a long Shadow distance no
  longer pushes the merge out past 192 tiles (at 400 nothing in view was merged zoomed out).
  `--far-merge-cap=<tiles>` sets the cap, 0 none (as 0.2.0).

### Loading models: memory and time at a join

- **Pictures left out of Godot's glTF reader** (`model_textures.gd` `strip_pictures`, `can_wire`, `_wire`):
  Godot 4.7's reader decodes every picture a .glb holds even when told to discard them
  (`GLTFState.HANDLE_BINARY_DISCARD_TEXTURES` only skips making the textures; measured 470 ms either way for
  Vasillo's drill). A .glb whose pictures are all its own PNG or JPEG is handed to the reader with each picture
  a 1 x 1 PNG, and Zenith puts the textures the JSON names on each material itself: each picture decoded once
  for all models (Vasillo's `Zenith.zip`: 577 pictures in the files, 137 different). The materials, meshes
  and textures come out the same (`tests/model_pictures_test.gd`). `--model-pictures=godot`: as before.
- **Each .glb read once** (`model_library.gd` `Load.read_model`): the file is read from disk once and handed
  to Godot's reader, the pictures and a baked animation (each read it again before). `--model-read-once=off`
  (with the pictures wired as above, the .glb is still read whole for that wiring: `--model-pictures=godot`
  as well for the old path entirely).
- **Pictures kept on disk** (`model_textures.gd` `_read_cache`, `_write_cache`): a model's picture, once
  decoded and mipmapped, is kept in `user://tex-cache/model-<md5>-<size>.bin` (FastLZ, with its 64 px copy
  and its counts); the next start reads it instead of decoding the PNG and making its mipmaps. At most 2 GB,
  the oldest going first. `--tex-cache=off` (shared with the ground's textures): no disk cache.
- **Models read at once bounded by size** (`model_library.gd` `poll`, `load_bytes`): models start reading
  while those being read hold under 512 MB of .glb files between them (one alone may be larger), besides the
  count (`load_jobs`). `--model-load-mb=<MB>` changes it, `0` no bound (count only, as before).
- **The worker pool** (Godot's `threading/worker_pool/max_threads`, `low_priority_thread_ratio`): every
  loading job (models, terrain, far merges, Distant Horizon) is a low-priority task, and Godot gives those
  30% of the pool: 4 threads of a 16-thread CPU, so `world.gd` `set_joining()` raising the model jobs past 4
  changes nothing. To cap the pool on a machine with little memory or many cores, put a
  `client/override.cfg` (beside `Zenith.exe` in a download) with
  `[threading]` / `worker_pool/max_threads=8` (Godot's own override file; delete it to undo). What it costs,
  measured on the Zenith Test save's join (16 threads, headless): 2 low-priority threads (pool of 8) took
  40.5 s from ready to drawn against 21.7 s (today's 4); a ratio of 0.8 (12 threads,
  `worker_pool/low_priority_thread_ratio=0.8`) 18.1 s, with 2-3 times the paging. Memory is not saved by a
  smaller pool in these runs (2.6-2.7 GB either way); leave it alone unless the CPU is shared.

### CPU, streaming and GPU tuning switches

- **Fast entity ingestion and batched joins** (`world.gd` `fast_add`): integer prototype flags, static-key bypasses for connectable/belt tracking sets, and batched wall/belt/pipe/cargo joins per `"ents"` chunk packet. `--world-fast-add=off` classifies and joins each record individually.
- **Row-run shadow and far-chunk visibility diffs** (`world.gd` `shadow_row_runs`, `far_chunks.gd` `decide_row_runs`): track chunk spans per row and update only boundary diffs when panning. `--shadow-runs=off` and `--far-decide-runs=off` rescan all loaded chunks; `--far-prep-guard=off` skips cancelling in-flight merged worker `ChunkPrepJob`s when a far chunk comes near.
- **Incremental subscription window and row-grid RLE** (`world.gd` `sub_incremental`): shifts `PackedByteArray` visibility rows in O(side) and encodes `square_rows_from_rows` directly without hashing vectors. `--sub-incremental=off` rebuilds wanted/subscribed lists in full.
- **Per-record model cache and MultiMesh worker prep** (`chunk_view.gd` `build_rec_cache`, `chunk_mm_worker`): caches static entity mesh/transform/part lookups on `Rec` and packs MultiMesh buffers + `ContactShade.prepare()` on `WorkerThreadPool` for chunks with `>= 48` instances. `--build-rec-cache=off` and `--chunk-mm-worker=off` restore uncached main-thread builds.
- **Native chunk build** (`ChunkBuildNative`, `client/native/belt_sim/src/chunk_build_native.cpp`): `ChunkPrepJob.pack_buffer` and `box_bounds` (the per-instance MultiMesh row packing and bounds loops) in C++, identical output; the GDScript stays when the class is missing. `--native-chunk-build=off` forces the GDScript loops. Test: `tests/chunk_build_native_test.gd`.
- **Belt stand-in camera deadband & time-slicing** (`belt_lods.gd` `move_deadband`, `slice_enabled`): quantizes camera motion (`>= 4` tiles, distance-scaled) and slices `>= 64`-chunk belt checks under `FrameBudget`. `--belt-lods-every-frame` checks every transform change; `--belt-lods-slice=off` runs unbudgeted full-world single-frame `BeltLods` checks.
- **Camera-zoom-scaled character LOD, belt stand-in, far merge, and SSAO** (`view_priority.gd`, `world.gd`, `belt_lods.gd`, `far_chunks.gd`, `ao_zoom.gd`): `--char-lod-zoom=off` restores fixed character-anchored LOD, belt stand-in, far-chunk merge, and SSAO distances that ignore camera zoom distance in normal play.
- **Capped grass zoom, dual-paraboloid lantern, and SSIL zoom fade** (`decoratives.gd`, `avatar.gd`, `ao_zoom.gd`): `--grass-zoom-lines=raw` uses unclipped viewport lines for 3D grass; `--lantern-shadow=cube` uses 6-face cube shadows instead of dual-paraboloid on the character lantern; `--ssil-zoom-fade=off` leaves SSIL on across all zooms instead of fading out alongside SSAO.
- **Grade focus uniform and fast night clouds** (`looks.gd`, `cinematic_grade.gdshader`): `--grade-focus-uniform=off` samples depth per pixel in the grade shader instead of using the uploaded camera focus distance; `--fast-night-clouds=off` keeps full 14-step cloud marching and solar lookups at deep night.
- **Cliffs' shadows and far merges on the low ground** (`model_lods.gd`, `far_chunks.gd`, `shadow_stand_in.gdshader`, `far_merged.gdshader`): a cliff's rock sits on the ground without its cliffs' terraces (Terrain Elevation), and its shadow stand-in and far merge are now lifted the same way; lifted by the terraced ground, the stand-in floated up to 2.2 tiles over the rock and shaded all of it and the ground at its foot (cliffs near black in daylight). `--cliff-low-shadow=old` lifts them by the terraced ground as before.
- **Cliffs seated in their terrace** (`ground_height.gdshaderinc` `ground_lift_cliff`, its CPU twin `GroundHeight.cliff_lift`; `factorio_material.gdshaderinc`, `shadow_stand_in.gdshader`, `far_merged.gdshader`, `lod_common.gdshaderinc`): with a height field's terraces (Terrain Elevation), a cliff's rock stands on the low ground, grown with a terrace taller than 2 tiles (`max(1, D / 2)` times, D the terrace's height within 3 tiles; never smaller than Factorio's) and never more than 0.1 tile under the high ground; its shadow stand-in, its far merge and the distant horizon's cliff blocks (lod kind 4, Factorio's cliffs only, not rocks) are seated the same way (those blocks were lifted by the terraced ground and stood a block over the plateau's edge). Flat ground or no cliff near: as before. `--cliff-fit=off`: the rock on the low ground at its own height and the blocks on the terraced ground, as before. Terrain Elevation 0.1.7 moves its step onto the cliff's line to match (its own setting *Step on the cliff's line*).
- **Flat ground in front of a cliff shaded flat** (`ground_height.gdshaderinc` `ground_n`, CPU twin `GroundHeight.normal`): with a height field's low ground (cliffs' terraces), the ground's shading normal takes the hills' slope a texel either side as before and the terraces' part (the ground less the low ground) half a tile either side; read a 2-tile texel out, the flat ground 0.5-2.5 tiles in front of every cliff was shaded as a 21-33 degree slope and lost its decoratives (they fade out on steep ground), a pale groove along the rock's foot. Also the decoratives' and the distant horizon's levels. `--cliff-ground-normal=old`: as before. Terrain Elevation 0.1.8 fixes the field's own groove there (*Step follows the rock*).
- **Hills worked out in C++** (`TerrainFieldNative`, `client/native/belt_sim/src/terrain_field_native.cpp`; `api.terrain.native()`): Terrain Elevation 0.1.11's *Fast native maths* (on) works its height field's stages (the hills' noise with Godot's own FastNoiseLite on up to 8 threads, the cliffs' terraces, the water's distance, shores and edges, the buildings' pads, the image's floats) in the native library, to the same floats as its GDScript: a 768 x 768 field with 1,000 cliffs, water and 4,000 buildings 1.0-1.4 s -> 37-55 ms. `--terrain-native=off` (or the add-on's setting off, or a platform without the library): its GDScript, as before.
- **A new hills field without the materials' churn** (`ground_height.gd` `swap_old`): the height texture and the faded-from texture are set into the shaders' globals once and updated in place; a fade copies the field shown into the faded-from texture (a second upload) instead of swapping the two globals, which made Godot update every material reading them (the ground and every model the hills lift) on the render thread each time Terrain Elevation sent a field. Terrain Elevation 0.1.9 sends fewer fields (*Calm redraws*, *Quick building updates*: a building redoes only the ground round it, unfaded, and nothing is sent when no height changed). `--ground-swap=old`: the textures swapped as before.
- **Movers lifted whole onto hills** (`factorio_material.gdshaderinc` `ground_rigid`, `ground_lift_rigid`, instance uniform `f3d_lift_at`; movers.gd, creatures.gd, avatar.gd): with a height field (Terrain Elevation) the character, cars, tanks (body and moving parts together), creatures and robots take one height, the ground's under their origin, instead of a lift per vertex that bent them over a cliff's step. Trains, spidertrons, pentapods and buildings as before. `--mover-lift=vertex`: every vertex by its own ground, as before.
- **No pits under vehicles** (`addon_terrain.gd` `buildings_in_chunk`): cars, tanks, spidertrons, locomotives and wagons are not given to a terrain add-on to level the ground under (a parked car sat in a pit cut to its centre's height); rails still are, so trains sit on them. A vehicle is bent onto the hills vertex by vertex, not tilted as a body.
- **Bare ground by cliffs** (`terrain_common.gdshaderinc`, `GroundHeight.cliff_near`): a height field's third channel (blue, how near a cliff, 0-1: `api.terrain` takes `FORMAT_RGBF`) tints the ground towards Factorio's cliffs' scree (`#61492f`), up to 55% by the rock, keeping the picture's light and dark; not on a player's floor or the shore's shelves. `--cliff-ground-tint=off`: no tint. The tint is ragged scree (patches with a broken edge, colours between `#61492f` and the wall's apron `#7a6040`); `--cliff-scree-look=old`: the even band as before. Terrain Elevation 0.1.7 gives the channel (its setting *Bare ground by cliffs*). Not in `--terrain-opt=old`'s single shader.
- **Cliffs as one fused wall, with variants** (`tools/models/nature/cliffs.py`, Placeholders pack, `model_library.gd` `cliff_piece`): Nauvis's cliff pieces are one wall of upright blocks of uneven width standing shoulder to shoulder, a ragged top line, shorter blocks in front, a pale scree apron at the foot and pale crest stones (Factorio's cliff sprites and their lower layer), with seeded variants drawn by position like other models' (`cliff-sides-1`..`-3`, `cliff-outer-1`/`-2`, `cliff-inner-1`/`-2`, `cliff-exit-1`, `cliff-entrance-1`; `--model-variants=off` draws only the plain pieces). Every piece and variant has the same cross-section at its cell's edge, so any joins any. `--cliff-pieces=old` draws the first pieces (separate columns on a ridge, kept as `cliff-<piece>-old.glb`, never picked as a variant); other planets' cliffs are unchanged. Rebuild: `blender --background --factory-startup --python tools/models/nature/build_nature.py -- <names>`, then `tools/models/part_colors.py <names>` and `tools/models/bake_pbr.py --names <names> --fix-imports`.
- **The gate reads as a gate** (`tools/models/railway.py` `gate`, Placeholders pack, `model_library.gd` `gate_model_old`): the door (`anim_gate_door`, sunk into the ground to open as before) is dark steel plates with Factorio's bold diagonal yellow-and-black hazard stripes on both long faces and yellow caps with dark slots along its crown; what stays when it is down is the frame: pale steel ground rails either side of the dark slot and a dark buttress housing in the middle of each side, each with a small amber warning light (emission, seen at night). Pieces in a row still join edge to edge, both orientations as before. Its colours are forced in `part_colors_overrides/nauvis.py` (the sprite sample had greyed the yellow to the stone wall's colour). `--gate-model=old` draws the model it had before (pale stripes, low rails), kept as `gate-old.glb`. Rebuild: `python tools/models/noblender.py gate` (or Blender's `build.py -- gate`), then `tools/models/part_colors.py gate` and `tools/models/bake_pbr.py --names gate --fix-imports`.
- **Cliffs as one generated wall** (`cliff_wall.gd`; on by default; `--cliff-wall=off` or Settings → Graphics → *Cliffs as one wall* off gives the pack's pieces, `--cliff-wall=on` forces the wall): a flat top (deck) 2 tiles over the low ground reaches 2.6 tiles back from the line and covers Terrain Elevation's high-side ramp (the seat grows it by terrace / 2, so it lands on a terrace's top), its back lip tucked into the high ground; the scree apron reaches 2.6 tiles out over the low-side ramp, its foot riding just over the ground (`ground_lift_cliff_wall`, the material's `cliff_wall`) so no terrain shows in front of the face; crest stones lie on the deck. Without a terrace the deck is a 2-tile plateau dropping to the ground behind. Nauvis's cliffs drawn as one mesh a chunk along their chains instead of the pack's pieces, with the pieces' look (the fused-wall body, blocks of uneven width with a ragged top line, shorter blocks in front, pale crest stones, a scree apron). Each 4x4 cell is seeded by its position and each joint (the block across a cell's edge and the body's cross-section there) by that edge's position, so neighbours weld without walking the chain. Seated as the pieces are (`ground_low`, `ground_lift_cliff`: the foot on the low ground, the top on the high ground). Built on worker threads and put in under the frame budget (`cliff_wall`); three levels of detail by the distance to the chunk's wall (0-40, 40-96, 96+ tiles, times the Level of detail setting's distance scale), its coarsest level as the shadow stand-in (the low-ground stand-in material; the wall casts itself where stand-ins can't, under an orthographic camera), and hidden while a far merge stands for the chunk (the merge draws the pack's pieces, seated the same way). A pack other than Placeholders that draws Nauvis's cliffs keeps them (the pack wins); other planets' cliffs keep their pieces. With `--cliff-pieces=old` the wall still wins when it is on.
- **Ghost coarse LODs, warm-ring tuning, belt-lane vertex cull, tree shadow decimation, and coarse far HLOD** (`ghosts.gd`, `world.gd`, `belt_lanes.gd`, `model_lods.gd`, `far_chunks.gd`): `--ghost-lod=off` keeps full-detail meshes for far ghosts; `--warm-rings=<n>` sets warm ring retention (`0..12`, default `4`); `--belt-lane-vcull=off` skips vertex-stage lane distance culling; `--tree-shadow-decimate=off` keeps all non-core leaf cards in tree shadow stand-ins; `--far-coarse=off` disables the outer `0.8 m` coarse far-merge HLOD tier.
- **Megabase main-thread caching and batching switches** (`quality_marks.gd`, `inserter_arms.gd`, `movers.gd`, `alt_overlay.gd`, `alt_arrows.gd`): `--quality-marks-static-cache=off` rebuilds all entity quality-mark transforms every refresh instead of caching static entities; `--quality-marks-opt=off` restores unthrottled belt-item quality polling/uploads in `quality_marks.gd`; `--rest-arms-chunked=off` rebuilds one global resting-arms `MultiMesh` buffer instead of updating only dirty per-chunk `MultiMeshInstance3D` nodes; `--inserter-fast-upload=off` restores per-instance `set_instance_transform()` uploads for live inserter arms instead of bulk MultiMesh buffer uploads; `--mover-pick-all` scans every GPU robot record during entity picking instead of node-backed movers; `--alt-flat-batch=off` interleaves each quality mark after its icon in `_flat` Alt-mode instead of drawing icons before texture-grouped marks; `--alt-cache=off` restores uncached per-frame `AltOverlay` collection/redraw; `--alt-flat-batch-tex=off` restores the unbatched depth-ordered `_flat` draw path above `layer_cap`; `--alt-arrows-opt=off` restores per-frame string-key and buffer reallocs in `alt_arrows.gd`.
- **Render distance & Distant horizon** (`render_distance.gd`, `distant_horizon.gd`, `lod_mesher.gd`, `lod_data.gd`, `lod_cache.gd`, `lod.lua`, `far_chunks.gd`): By default (**Manual horizon split** on, `graphics.distant_horizon_manual`, or `--render-distance-split=manual`) `Settings > Graphics` has separate `View distance (full)` (`graphics.view_radius`, `2..50`), `Distant horizon` (`graphics.distant_horizon`, `0..512`), `Distant horizon detail`, and `Distant horizon LOD dropoff` controls. Turning Manual horizon split off (or `--render-distance-split=unified`, which wins over the setting) gives one `Render distance` slider (`graphics.view_radius`, `2..512` chunks) plus `Level of detail` (`Low`/`Medium`/`High`/`Ultra`) as one seamless pipeline, balancing close full-3D chunks (`5..18` chunks), `FarChunks` HLOD merging (`lod_scale`), and `DistantHorizon` rings out to the chosen distance; the UPS governor downsizing real chunks then backfills with DH. `--lod-anchor=camera` turns off the character-anchored LODs. `--dh-seam-fade=off` disables smooth 0.30s Bayer cross-fade at the loaded-chunk seam, `--dh-handoff=off` disables load-underneath mask grace frames, extended DH reveal hold, and unload-takeover holding, and `--dh-async-io=off` restores legacy sync `LodCache` region reads and main-thread region encoding. `--distant-horizon=off|<chunks>` (`16..512`) overrides the radius and `hello` `lod` opt-in; `--distant-horizon-quality=minimal|low|medium|high|ultra`, `--distant-horizon-dropoff=near|balanced|far`, `--distant-horizon-detail-lod=off|on`, and `--lod-night-glow=off|on` tune DH directly. The colour table
is refreshed (a ground texture arrived, or 8 more far-merge model bakes) by a snapshot on the main thread
and a build on a worker; only the sections whose last build held a tile or entity whose colours changed
are drawn again, checked 1 ms a frame (none when nothing changed), and the sections to build are scanned
and sorted at most every 0.25 s (at once when the list runs out or chunks wait to be handed over).
`--dh-palette=old` rebuilds it on the main thread, draws every section again and scans and sorts every
frame, as before (10-18 ms a rebuild and 150-260 ms of re-sampling after it on Zenith Test). The charted
map (`lodm`) is kept as its rows' runs, not one entry a chunk (360k chunks: 20 ms against 560 ms headless);
`--dh-map=old` keeps one entry a chunk. Region caches live in `user://lod-cache/` (`Zstd`, 256 MB LRU), and `user://pollution-cache/` (`Zstd`, disabled by `--smog-cache=off`) persists pollution to dye Distant Horizon trees and water out to 512 chunks consistently across reloads.
- **Camera cone** (`view_priority.gd`, `addon_host.gd`, `world.gd`): an add-on or Cinematic camera's view cone sets where the chunk streaming looks (`world.set_view_cone`, passed by the add-on host each frame from `rig.use_view_cone()`). The streaming part is **off by default** (it has not been run in play): `--camera-cone=on` tries it; its chunk boxes grow with Terrain Elevation's hills (`GroundHeight.lift_range()`) and it sends the whole chunk list on a cone change, not the incremental one. `--camera-cone=off` also switches off the cone's other users (add-on focus point, decoratives, behind-cull).
- **Fast & seamless world streaming switches** (`world.gd`, `chunk_view.gd`, `behind_cull.gd`, `far_chunks.gd`, `frame_budget.gd`, `chunk_disk_cache.gd`, `lod_cache.gd`, `belt_lods.gd`, `settings.gd`):
  - `--atomic-chunk-reveal=off`: show chunk terrain immediately when meshed rather than holding ground visibility (`REVEAL_HOLD_MSEC = 600` timeout) until initial entity builds / far-chunk merges finish (`chunk_ready` signal).
  - `--double-buffer-refresh=off`: clear existing chunk entities immediately on incoming `"chunk"` headers rather than staging multi-part `"ents"` snapshots and swapping atomically.
  - `--far-priority=legacy`: keep uncovered `far_collect` / `far_install` merges at Priority 8 with a `0` frame-budget floor instead of promoting uncovered outer-ring merges above clutter/wires.
  - `--optimistic-cache=off`: wait for server `same` before mounting RAM/disk-cached chunks when re-entering an area.
  - `--optimistic-slice=off`: replay a cached chunk (RAM or disk cache) whole in one call, the clock checked only between chunks, as before. On (default): one step at a time (its chunk message, each entities message, its deltas, its decoratives) inside the frame budget's `hydrate` slice (priority 2, 2.5 ms, floor 0.5 ms), the clock and the next step's typical cost checked between steps; a part-way chunk goes on next frame and is dropped when the bridge's own snapshot or `same` arrives or the chunk unloads. A cached chunk may appear a frame or two later.
  - `--chunk-disk-cache=off` / `--chunk-disk-cache-mb=<N>` (Settings > Graphics `"chunk_disk_cache"`, default on / `512 MB`): disable or cap the persistent Zstd 16x16-chunk cache in `user://chunk-cache/`.
  - `--chunk-disk-cache-async=off`: restore legacy main-thread disk-cache JSON stringification and region encoding instead of background `WorkerThreadPool` encoding.
  - `--dh-async-io=off`: restore legacy synchronous Distant Horizon `LodCache` region reads and main-thread region encoding.
  - `--lod-fade-moving=off`: keep spawning LOD cross-fade nodes while moving above `12` tiles/s instead of snapping LOD transitions.
  - `--budget-hard-cap=off`: restore legacy unbounded `FrameBudget` floor stacking across low-priority systems once total work hits the frame ceiling.
  - `--budget-spent=off`: grants ignore the frame's other (unbudgeted) scripts' time already spent this frame. On (default): what they spent past their usual share (their smoothed time a whole frame) comes off every grant, even with the pool clamped at its 6 ms ceiling; floors and the reducing systems' raise (`REDUCERS`) still apply after it.
  - `--budget-predict=off`: sliced systems check only the clock between items. On (default): messages (by type), far belt icons (`lanes`), Distant Horizon section installs (`lod_install`), wires and cached-chunk steps count the next item's typical cost (`FrameBudget.item_est`: up halfway at once on a slow item, down 10% an item) before starting it, so a slice stops before an item that won't fit rather than after; the first item of a slice always runs.
  - `--unload-fast=off` (P4: "5 seconds after looking away to gain FPS", "running leaves rendered chunks and LODs"): restore the old unloading. On (default): the systems that take drawing away (`lods`, `belt_lods`, `shadows`, `far_decide`, `far_collect`, `far_install`) keep a floor (`FrameBudget.REDUCERS`, together at most 2.5 ms) past the hard cap and the frame's deadline while they have work (in frames over 16.7 ms they had a 0.5 ms slice about every 20 frames: after first-person laps 361 chunks' levels of detail and 269 far chunks waited for good, 7,700 draw calls instead of 2,800); far gathering takes 3 slices while 16+ chunks wait; behind-cull hides queued chunks farthest first for 3 ms a frame (at least the old 8 / 32); chunks kept past the square (`WARM_RINGS`) are hidden (Distant Horizon told) and shown again unrebuilt when the square returns; unloaded chunks are hidden for at least 3 ms a frame.
  - `--belt-lods-slice=off`: restore legacy unbudgeted full-world single-frame `BeltLods` checks instead of slicing `>= 64` chunks under `FrameBudget`.
  - `--behind-cull-show-slice=off`: show all newly in-view chunks and emit `chunk_visibility_changed` signals in one frame instead of keeping a 3-chunk collar immediate while slicing far reveals.
  - `--stream-window=legacy|<N>`: restore fixed `STREAM_MOVING = 12` / `STREAM_STILL = 32` non-sliding subscription throttling (`legacy`), or force a custom in-flight chunk limit `<N>` (`0` / omitted = adaptive window scaled by view radius & build backlog).
  - `--stream-lookahead=off`: disable flight-velocity priority biasing along movement direction.
- **3D item LOD, variant, shadow-proxy and tangent switches** (`belt_lanes.gd`, `belt_lattice.gd`, `item_cards.gd`, `item_models.gd`, `belt_items.gd`): `--far-belt-3d-dist=<tiles|all>` (default `48` at Medium LOD quality, `all` renders LOD1 3D models to full `bfar` distance); `--far-belt-variants=on` (keeps multi-variant models on far chunks instead of 1); `--far-item-pbr=full` (keeps normal and ORM texture fetches on far 3D belt items); `--lattice-variants=close|all|off` (default `close`, switches off extra ore/coal/stone variants past `24` tiles); `--lattice-model-cap=off` (legacy binary `< 0` all-or-nothing `Items in 3D` cap on packed lattice lanes instead of smooth nearest-first scaling); `--item-lod-split=off` (legacy single-MultiMesh multi-surface shader collapse across all items instead of distance-banded MultiMeshes); `--item-geom-lod=off` (disables auto geometric LOD1 and LOD2 proxy fallback on near belt items, falling back to `--item-lod=off`-controlled distance LOD); `--item-lod-mode=global` (restores legacy zoom-based global item LOD tiers instead of per-instance distance rings); `--item-lod-bands=all` (keeps the flat character-anchored band edges, 28 / 56 tiles at Medium, at any zoom; the default `zoom` also moves an item to the mid / far band once it is under 36 / 18 pixels a tile on screen, so zoomed out each belt item is drawn by its cheap far band, the 10-triangle proxy box or icon card); `--item-lod2=icon` (restores 2D Factorio icon cards at LOD2 and past `--far-belt-3d-dist` instead of 10-triangle model-matched proxy boxes); `--item-lod-blend=off` (disables gradual shader shading fade and per-item distance jitter between item LOD bands); `--item-shadow-proxy=off` (casts shadows from full item meshes instead of 12-triangle box proxies); `--item-tangents=off` (uses screen-space cotangent derivatives instead of precomputed vertex tangents for item normal maps).
