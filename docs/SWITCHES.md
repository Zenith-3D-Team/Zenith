# Switches and Settings Reference

All `--flag` client switches, `/f3d-perf`, and `/f3d-bs` bridge commands, moved from [RUNNING.md](RUNNING.md). Deep probe and optimization logs live in [PROFILING-NOTES.md](PROFILING-NOTES.md).

> **Contents:** [Bridge Cost, `/f3d-bs` & `/f3d-perf`](#what-the-bridge-costs) · [Client Controls & Gameplay](#client-controls) · [Looks & Shaders](#looks) · [Decoratives, Trees & Skies](#decoratives) · [Additional Client Flags (A–Z)](#additional-client-flags-from-troubleshooting) · [Menu, Mock, Relay & Native Flags](#menu-launch-mock-relay--native-switches-from-running-guide)

### What the bridge costs

#### Profiling & Busy Base

`/f3d-profile` turns per-module timing on (and off); after 10 s `/f3d-status` lists each module's
average script time per tick (`transport`, `world` (chunk snapshots), `movers`, `belt_items`,
`inserters`, ...). To try it on a busy base, `python3 tools/busy_base.py` builds one next to the
bridge's character on a test save (loops of belts full of moving plates, a block of assemblers
fed by inserters, power), profiles for 12 s and prints the report; `--clear` removes it again.
`--big` adds a main bus, a train, a robot network and a block of walls (20,000+ entities), and
`--measure out.json` connects a client of its own instead of needing one: it records each
module's time, the game's UPS with and without the bridge serving, chunk snapshot time, bytes per
second by message type and a call-by-call breakdown of reading belt items. CI's `busy` job runs
`--big --measure` against `tools/busy_budget.json` and fails when the bridge costs more than
twice the budget. On CI's runners the bridge costs about 6 ms per tick with 3,700 belt items in
view, nearly all of it `belt_items`; the game keeps 60 UPS. On a laptop with `--big` (about 25,000
entities) and the windowed client connected it costs about 15 ms a tick. For a client that says
`bl` in its hello (Zenith does; `busy_base.py --measure`'s own client doesn't), a belt lane whose
item count and front and back items haven't moved isn't read or sent again: on the owner's save
at its busiest belts that took `belt_items` from 12-15 to about 5 ms a tick. (A full belt that
flows moves whole item gaps between some checks and would look unchanged, so every other update
is read a tick early, and a check that can't tell reads the lane in full.) If a module is expensive, the "Belt item, ground item and inserter radius" and "update interval"
settings below are the first things to turn down.

#### Work Budget & Update Rates

Two things keep the bridge from making a slow tick. **The work budget** (`scripts/budget.lua`):
everything that can be big (chunk snapshots, map charts, the handshake, another planet's remote
view, Factoriopedia, statistics, the trains on the map, hover info) is done in slices, paid from
300 work units a tick by default (about one entity read each); the client may change it
(`budget`, 50 to 20000) and hears once a second how it is used (`wb`, docs/PROTOCOL.md "Work
budget"). **Update rates** (`scripts/rate.lua`): at `rate` level 1 to 3 the costliest periodic
updates (belt items, far lanes, movers, then machine states, enemies, plants and spawners, then
fluids, trains, turrets, inserter hands) come less often, each level doubling their interval; the character's own
updates never slow. A `bs` client's belt updates (reads of the input spots, not glided positions) slow
not at all by default (`/f3d-bs own_rate` and `period_max`, below: `period_max 0` stretches them to 12 ticks at level 3, as before). Hold the game at 60 UPS sets both; `/f3d-rate 0-3` sets the level by hand, `/f3d-rate <0-3> hold` holds it against the clients' `rate` commands until `/f3d-rate free` (measuring one level). While
the bridge makes its first load of the belts (joining, a jump: `bs` with `ld` while the square loaded is
under 3/4 of the belt item distance) and 3 s after, Hold 60 UPS takes no step and keeps the budget at 150
or more; the load done, the budget is back at its default (ups_governor.gd).

**Fast budget cut** (`--budget-fast=on|off`, on; `ups_governor.gd`): Lua can't read a clock, so the client times the
ticks' arrival. When the ticks that arrived over the last quarter second come to under 50 a second (a normal quarter
second holds 15; a 130 ms tick in it reads about 50 or less), the work budget is cut by 30% at once (to 60 units at
least) and sent with the usual `budget` command, at most every quarter second, instead of waiting for the 3 s
reading and the half-second cadence. The growing back is unchanged (the 10 s reading at 59 UPS). Nothing is cut
while the first load runs or for 8 s after, during a screenshot's full detail, with Hold 60 UPS off, with
`--bridge-budget=` pinned, in the first 10 s after joining, or when no tick at all arrived in the window (a save's or pause's first quarter second reads as a long tick and may
cut once or twice; after that nothing more). Off: only the 3 s rule. It cannot make a long tick shorter, only shrinks the next ones'
slices of chunk, map and train work.

**Megabase saves and ticks over 33 ms**: a save stalls the server for as long as the map takes to write (seconds on a
megabase), and every client sees it as one huge tick. Choose a longer autosave interval in Settings → Other (the
server's autosave interval; 10-20 minutes on a big base, `autosave_interval` in `server-settings.json`) and fewer
slots. `non_blocking_saving` (`server-settings.json`, off by default; the performance test's settings file keeps it
off) lets a Linux server save in a forked process so the game doesn't stop for the write; Factorio marks it
experimental and it needs Linux (a Windows server ignores it), and it uses extra memory while the save runs. It
needs no change in Zenith. A save made by hand with `/server-save` stalls the same way.

#### Belt Simulation Switches (`/f3d-bs`)

**Belt simulation switches** (`scripts/belt_sim.lua`, a `bs` client): `/f3d-bs` (console or RCON, no
restart) lists them; `/f3d-bs <name> on|off|default` sets one for every client (kept in the save), the
old behaviour back when off. `feed_edges`: lanes fed from outside what is sent are checked on every
update's tick, never quiet, and sent whenever they changed. `full_area`: every belt within the client's
belt item distance is simulated (off: its Belt updates cap and the entity distance bound the square, as
before). `inputs_first`: inserters and drills that use belts are checked themselves (their hands, their
mining progress) and wake their belts; input spots come before the other checks, the accuracy reads
outside the steady limit. `line_rereads`: lanes asked for again (`bre`) are read in groups on one tick
with their packed runs. `/f3d-bs bound <share>`: the share of the work budget the belts' work a tick may
take before the square is cut from the outside (default 0.6; 0: never cut). What they cost at 160 tiles:
`actor_backoff` (inserters whose hand stood for 4 checks are checked every other update, drills about when
their progress comes round), `drift_far` (drift checks half as often from 48 tiles, a quarter as often from
96), `bre_cap <lanes>` (at most that many asked lanes read an update, in the order asked, the rest
waiting their turn, at most 2,048; default 192, 0: all), `quiet_backoff` (watched lanes standing for 6 and 12 checks are checked 2 and 4 times
less often), `pc_ids` (every packed lane's drift check carries its front and back items' ids, `pu`,
outside the accuracy extras' share: off, only while that share has room, which at 160 tiles was 61 of
85,080 packed checks, so a packed lane the client had a whole gap or more off by its ids never showed;
off by default, as it changed nothing measured), `hold_inputs` (a splitter's input found at its check as the
client's last read of it left it, a packed one by its front and back items' ids too, is sent in `sh`: the
client puts it back so and holds its items there, not crossing into the outputs, until its next read; the
game's own update order holds a backed-up balancer's input a tick or more where the belt rules let its item
go, and a watched lane is sent only when the game's changes, so the client's balancers drained where the
game's stood). The others on by default. `area square|trace` (the owner's design; default square): with
`trace` the bridge loads only the belts within `trace_near` tiles of the focus (default 48: what the
player sees at the normal zoom, about 107 x 60 tiles), the belts feeding them traced back to their
origins (at most `trace_hops` belts back, default 200; an origin is a belt nothing loaded feeds, whose
inserters and drills are the input checkpoints) and the belts they feed `trace_down` belts on (default 8;
where a line is cut its exit lane's wall is watched every update, `ew`). Belts within the belt item
distance that don't feed what is seen aren't loaded (their far lane icons stay); `fr` is then the near
square, and the far lanes leave out the traced belts beyond it. `checkpoints` (off by default): the lanes
where our copy of the belt rules is known to go a tick from the game's (a splitter's inputs, a lane an
inserter takes from, an underground entrance an inserter drops on) are checked every update, never
quiet, packed ones by their ids. `crossings sim|game|hints` (default `hints`): with `hints` splitters' outputs are
watched as with `sim` (quiet when standing), and when a side's outputs changed, unless its lanes are all packed
end to end with one kind of item (stacked or not; 2 items fill a splitter's output or input, 4 a belt's lane), a
few crossing hints go (`bs` `sx`: the items on its outputs and at its inputs' fronts, by unique id; no input sent
in full), which the client follows (`--belt-sim-split-hints`); an output packed with mixed items is checked by its
ids too, so a packed flow sends hints and no `sl`. Hints and those id checks have their own `hint_units` (400 work units an
update, apart from the 2,000 `extra_units`, so the id and tail reads can't starve them; none once the square is cut,
never over the bound) and go only to a client that reads them (JSON, or
binary wire version 5 or later). The old way: `crossings sim` with the client's
`--belt-sim-split-hints=off`. With `game` every splitter's output
lanes (lines 5-8, a lane splitter's 3-4) are checked on every update, never quiet, packed ones by their ids,
and read (`sl`) whenever anything but an even flow happened, so each crossing reaches the client within an
update of the game making it; measured offline on the 80 x 80 recording at -62,-26 (docs/BELT-SIM-PLAN.md,
the cross round) reads of the outputs every 6 ticks made the simulation worse than running the splitters
itself, so `game` isn't the default. With `/f3d-profile`, `/f3d-status` also lists the belt simulation's parts
quiet, packed ones by their ids. `own_rate` (on): the updates follow their own rate job (`bs` in
rate.lua: tier 3, at most 12 ticks), so the client's `rate` levels 1-2 (Hold 60 UPS's first steps) leave
them every 6 ticks and level 3 doubles them once; every update is a read of every input spot, so a
longer period is a staler bus, not a smoother glide (off: the glided belt items' job `bi`, 12, 24, 48
ticks at levels 1-3, as before, which under Hold 60 UPS left the owner's bus with gaps along every lane).
Hold 60 UPS then buys its UPS from the steps after `rate` (the minimap, the entity distance, the belt
item distance, which shrinks the square the bridge reads; its Moving belt items steps, 3000 and 1500, are the
belt cap, which a `bs` client's square ignores under `full_area`, so the governor skips them: `--ups-updates-steps=on`
takes them again). `period_max` (6, the detail interval: never stretched; 0: rate.lua's 12 ticks at level 3, as
before): the longest period `bs` is stretched to (measured at -62,-26: 6 ticks at level 3 cost 1-2.5 ms a tick of
bridge and about 1 UPS, and kept phantoms under the 2% gate in 4 of 5 runs where 12 ticks did in 1 of 6; visible the
same: "Update rates at the owner's belts", below).
Measured live at -62,-26 (Hold 60 UPS on, `--record 60`, 2 runs each): before, updates of 24-48 ticks at
rate 2-3, live visible 78-80%, phantoms 7-8%, the copper and iron buses mostly empty with streaks; with
`own_rate`, 12-tick updates at rate 3, live visible 79-81%, phantoms 8-10%, the buses mostly full with
scattered gaps (the score doesn't tell the pictures apart). The game ran at 30-50 UPS in every run with
the client's ~1 s jobs up, so the governor reached level 3 either way. `drift_watched` (off): on, watched belts' lanes (an inserter's or
drill's belt, the belt behind a pickup belt, a splitter, a loader, a wired belt) get drift checks (`pc`) in
the same turns as the rest, their own checks' quiet timing left as it was; off, as before, they had none:
a watched lane is sent only when the game's changes, so one the client got wrong while the game's stood
(a backed-up bus) stayed wrong. On the every-tick capture at -62,-26, 2.0% of the game's items were holes
on lanes that never got a drift check, 0.6% on lanes not read for 400 ticks or more. Off by default: on that
recording through the offline harness (600 ticks after a fast first load, `bre` answered) it sent a third
more drift checks and asks for nothing measurable (by place 95.42% on, 95.49% off; phantoms 2.21 / 2.17%). With `/f3d-profile`, `/f3d-status` also lists the belt simulation's parts
the client's ~1 s jobs up, so the governor reached level 3 either way. `walk_load` (units a tick, default 1200; 0 or off: as before) and `walk_near` (tiles, default 96): while the
square every belt of which is loaded (`fr`) reaches less than `walk_near` tiles from the focus (walking,
a jump: the view isn't all loaded), first loads get at least `walk_load` work units a tick instead of their
share of the work budget, which at Hold 60 UPS's budget floor is LOAD_MIN (400). Walking laps at
-62,-26 at the character's own speed, the bridge loaded about 14 lanes a tick: along the bus the loaded
square fell to 4-8 tiles round the character and the view showed a third of the bus's items
(tools/belt_walk_check.py, docs/BELT-SIM-PLAN.md's walk round); with `walk_load` 1200, 2 runs each,
visible while walking went from 65.0 / 87.2% to 91.2 / 93.6%, phantoms 2.1-2.2% on recorded lanes either way,
for about 0.5 ms a tick more while walking. Standing with the square loaded it changes nothing. `send_cap` (bytes a
tick, default 30000; 0 or off: as before): an update's parts (about 28 KB each) are sent over the ticks after its
due tick, about `send_cap` bytes a tick and one part at least, oldest update first, each part still stamped with its
update's tick (`k`), instead of all on the due tick; under a cap below 30000 the parts are made smaller with it
(about cap / 7.5 numbers), so a tick's bytes stay near the cap. Windows gives the client's UDP socket 64 KB: of three or more
parts sent in one tick the client lost the last ones whenever it hadn't read between them (0.1-1% of parts in
every join at -62,-26, always an update's last parts, lanes that then waited for their next read or a `bre`), and
the due tick carried the whole text cost (`bse.text`, 7-16 ms a due tick at 6 ticks). The spool is module-local:
only what is sent depends on it. Measured at -62,-26 (perfbridge round, 2 runs each, the join's first 90 s traced):
ticks sending over 64 KB 280 / 303 -> 6 / 9, `bs.emit` ticks over 20 ms 40 / 47 -> 3 / 5, the bridge's worst tick
130 / 130 -> 104 / 91 ms; lost parts 0.34 / 0.17% -> 0.67 / 0.05% (the client's I/O thread, polling every 1 ms at
below-normal priority, still misses two ticks' datagrams now and then), game UPS unchanged (median 40-44 either
way: the bridge's steady cost and the client beside it). With `/f3d-profile`, `/f3d-status` also lists the belt simulation's parts
(`bs.watch` watched belts, `bs.feed`/`bs.edge` lanes fed from outside and leading out, `bs.actor`
inserters and drills, `bs.drift`, `bs.bre`, `bs.load` first loads, `bs.scan`, `bs.queue` the update's
queue, `bs.emit` the message text; `bsq.*`, `bse.*` their pieces), each inside `belt_items`.
`extra_spread` (on; the perfbridge2 round): the reads made for accuracy alone (`extra_units`, 2,000 work units an
update: the packed runs round lanes the client asked for again, the tails of changed watched belts, the reads round
a settled one) are spread over the update's ticks, twice an even share (2 * 2000 / (period - 1)) a tick at most, the
rest of the steady queue waiting a tick (never on the due tick); off, they land wherever their step comes, which for
the asked lanes' runs was all on the round's first tick (`bs.bre` 6-11 ms there at -62,-26, the update's worst tick
after the due one; at an even share the asked groups took a tick apiece and held the watched belts' checks back to the
due tick). The same round made the bridge cheaper without a switch: the parts' numbers are written as text where they
are read, so a part's text is one `table.concat` a range instead of a loop in Lua over every number (most of
`bse.text`, 9-10 ms an update at -62,-26: 1.3 -> 0.4 ms a tick live); each lane's meta is kept for its re-sends (`bre`,
reloads); a lane of one item is read by its totals (one call instead of four); the lines' lengths are cached; the
movers' list is written as text with each mover's prototype id read once a search (a send of ~150 movers was 6.6 ms,
`helpers.table_to_json` and five calls a mover); the belts' scan reads at most two fresh chunks a tick once a scan
exists (`bs.scan` 30-85 ms on one tick when the chunk lists expired together). Measured at -62,-26 (the perfbridge2 round, docs/BELT-SIM-PLAN.md: the join's first 90 s traced, 2 runs each): the
bridge 13.1 / 12.0 -> 11.5 / 12.3 ms a tick median, p90 31 / 30 -> 26 / 26.5; the join's first 10 s 23.4 / 22.6 ->
18.6 / 18.4 ms median, ticks over 16.7 ms there 423 / 432 -> 353 / 333 of 600; game UPS median 40.8 / 43.0 -> 45.3 /
45.8, p10 31 -> 35.5; `bse.text` 1.3 -> 0.45 ms a tick, movers 2.0 -> 1.0-1.2; live visible 95.9% either way, phantoms
2.4-2.6% -> 2.0-2.8%.

The 0.2.1 hotfix's belt housekeeping (the bridge performance plan's change 3; each on by default, off: as before):
`quiet_first` (a watched belt whose lanes are all quiet is passed over before its `valid` is read: one call per
watched belt per update less; one gone without an event is dropped when its check comes up), `watch_nosort` (the
watched belts' order made with number sorts of their scan indices, no Lua comparator, and only when the watched
set, a spot or the scan changed, not whenever any belt loaded; the actors' list walked to its length at the round's
start instead of copied), `scan_step` (a new scan once the focus moved max(1, r / 32) tiles, 11 at 352, instead of
every tile; the square's middle lags the character by as much, its far edge alone), `far_load_cap` (first loads of
belts past `walk_near` get 400 units a tick unless the tick's work budget is three quarters unused, instead of half
the budget: the far edge on laps; only once the client's square has been loaded whole, so a join, a resync or a new
surface loads at the full share: capped from the join on, a cached join's belts finished loading at 23-27 s instead
of 9.6, with no better UPS meanwhile), `near_spool` (on; `/f3d-bs near_spool on|off|default`: belt simulation
spools (`bs`) generated within the near bubble around the player focus jump to the front of the `bs` send spool via
`near_spool`, so local belt builds, rotations, and lane edits flush even when outer chunks have parts waiting under
`send_cap`; off queues all `bs` chunks FIFO). Measured on the owner's base (art-src/perf-plans/after.md): the bridge's
belt part about as before settled, `bs.load` on laps 1.3-1.5 -> 1.07 ms.

#### Bridge Performance & Responsiveness (`/f3d-perf`)

**Performance switches** (`scripts/perf.lua`, the 0.2.1 hotfix): `/f3d-perf` (console or RCON, no restart) lists
them; `/f3d-perf <name> on|off|default` sets one for every client (kept in the save), the old behaviour back when
off. All on by default. `chunk_text`: chunk snapshots (`chunk`, `ents`, `dec`) are written as JSON text in the
snapshot's own slices, under the work budget, instead of `helpers.table_to_json` in the outbox's flush (which cost
0.3-0.5 ms a KB outside the budget: 1.4-2 ms a tick while chunks streamed on the owner's base, 40-65 ms ticks in
photo mode); the same messages on the wire, except that an empty list is `[]` instead of `{}`. `far_lanes`: a
belt-simulating client gets no far lane icons read where its square covers them: none at all once the square
reaches the far distance (the client's belt item distance is its far one, so every chunk once loaded), and chunks
wholly past the far distance from the square's middle aren't read for a margin. `wire_strips`: the look for wires
changed without an event (another player's hand, a blueprint pasted over poles, a script) reads the focus square in
8 strips, one every 30 ticks, so such a wire shows within 4 s instead of half a second (the whole square was 13.5 ms,
up to 49, twice a second); the client's own wire tools send theirs at once. `lightning_planets`: lightning is looked
for every 12 ticks only on planets whose prototype has it (Fulgora; the data stage lists them in the `zenith-planets`
mod-data), elsewhere every 300 ticks, for a script's `execute_lightning`. `states_near`: machine states within 64
tiles of the focus every 30 ticks as before, the rest of the focus square a quarter a round, so a machine further out
starts or stops its animation up to 2 s late. `requeue_slices`: a chunk queue of more than 512 put in a new order
(the view turned, the middle moved) by a job over the next ticks, 1,024 chunks a tick under the chunks' share of the
work budget, chunks still taken in the old order meanwhile, instead of all at once in the packet handler. Without a
switch, the chunk queue is taken from its head (`table.remove(queue, 1)` shifted the whole queue for each chunk:
60 us with 10,201 queued) and compacted every 1,024, and the chunks told as kept likewise. Not measured in the game
yet: the Lua tests check each against the old behaviour.

**Wide shots' effects radius** (`/f3d-perf shots_radius <8-256>|default`, a number, not on/off; kept in the save): projectiles, flame and acid streams, beams, explosions and ground fires (`pj`, `gf`) are sent within 48 tiles of the focus (the focus radius if smaller). A set value is the range round the focus whatever the focus radius, and the flying cap (400 projectiles, 2,400 beams' worth, 300 ground fires) grows in proportion (x radius/48). For a camera high over a base: `python tools/rcon.py "/f3d-perf shots_radius 256"` (a scratch server: the same through its RCON port). Cost: a quiet base nothing; in a big fight about 25-30 bytes per projectile, 40 per beam, 25 per fire per scan (every 2 ticks), so the cap's worst case at 256 is roughly 60 KB per scan; the search itself covers 28x the area at 256. `default` puts 48 back. The client draws whatever it is sent (no distance cut of its own).

The round after the hotfix (the bridge performance plan's changes 8-15), also `/f3d-perf` switches unless said:
`records_by_prototype` (on): a chunk record takes its prototype's type and id from a table made once a name instead
of reading `entity.type` five or six times, and natural entities (trees, rocks, ore, cliffs, fish) read only their
deconstruction mark, not their quality, upgrade and wires; the records are the same. `alerts_quiet` (on): the alerts
pass, which looks for the force's machines without power, fuel or ammo through every surface 32 chunks a tick, passes
over a chunk where it found none (a quarter of a chunk's price) until something is built, mined or changed there or
every tenth pass, and steps once a tick whatever the number of clients (its results are the same for all; with
clients of different forces the first one's). `one_search` (on): cargo pods (`cp`), spiders (`legs`), rolling stock
(`tr`) and enemy units (`en`) come from the movers' search of the focus square, which finds them anyway, by kind, not
from a search each of the same square (3-4 ms each on the owner's base); worms, which don't move, are searched every 300
ticks. How many of each the movers' search found goes into storage on its tick, so what those jobs keep there is the
same on every peer. A pod or train appearing with nothing else changed shows with the movers' next search (8-32 ticks
later) unless a rocket launch or a cargo pod setting off or arriving (their events) brings that search forward; a new
worm shows within 300 ticks. `robot_opt` (on by default; `/f3d-perf robot_opt off` to restore 60 Hz polling) caches force robot speed modifiers for 60 ticks, scales robot/charging/roboport cadences by rate factor and movement distance, uses `inv.is_empty()` for cargo reads, and caps work via the adaptive budget. `/f3d-bs two_call` (on by default; `/f3d-bs two_call off` for the four-call check every
time, kept in the save, and a save that never set it takes the default): a watched lane's check
reads its item count and its front item's place first and takes it as unchanged when both are as last seen, the
four-call check (stacks, back item) only when either differs and every fourth check anyway; not for lanes leading out
of the square or fed from outside it. What it adds to the check's blind spots: a stack count or the back item changing
with the count and the front the same, seen up to three checks late. Measured on the owner's base: 0.35 ms of bridge a
tick less settled, and as many of the game's items drawn at -62,-26 (97.8% visible, 1.2% phantoms). `/f3d-bs far_tier`
(off by default: no gain at 352 tiles on the owner's base, 40% more asks, a worse p99; it changes
when far belts are read), with `far_ring <tiles>` (96) and `far_units <belt units>` (1200; under 1 ms a tick at 6-tick
updates): the watched belts and the inserters and drills using belts within `far_ring` of the focus are checked every
update as before; those further out are checked in turn by a cursor that carries on where the last update stopped,
`far_units` an update (each at most once an update), an actor just before its belt so one that acted gets its belt read
in the same pass. Far watches skip downstream tail catch-up and `read_runs`, and `bre` asked groups run nearest-first
by scan index so `extra_units` stay near the character. The whole square stays loaded and simulated; every read still names its own tick, so a far input spot
read every second to fifth update reaches the client that much later (an inserter's drop 200 tiles away up to half a
second instead of 0.1 s). The far list is made again when the scan changes, else at most every 16 updates for one scan.
The plan's estimate: 0.9-1.4 ms a tick at the owner's settings; not measured.
`/f3d-bs target_spots` (on; off: as before): an inserter's or drill's belt is its pickup or drop target when the game
has one set and alive, else the belt on the tile of its pickup or drop spot. In 2.1 a drill has no `drop_target` until it
first puts something out (a replaced target stays a dead entity until then), and the bridge reads a chunk's targets
once and keeps them, so a drill placed before its belt, or a belt laid or replaced under a running drill, was never an
input spot: its belt wasn't watched and its items reached the client only when a drift check happened on one and the
client asked again (the owner's fresh world: on a copy of a new map, a drill feeding a 30-tile belt, 17-22% of the
game's items drawn on the 8 tiles nearest the drill, 85-88% over the belt; with 650 ms main-thread hitches every 2.5 s
0-10% of the moving items, 71-73% over the belt). An actor still without a target at an end is looked at again every
300 ticks, so one whose belt comes without an event (and a scan to find that belt) is found too.
`/f3d-bs built_now` (on; off: as before, K16, K22): a belt built, turned, replaced or removed is worked out on the next
tick, not at the next round's scan of the whole square. One built inside the square is loaded there and then (`lm`, `sl`,
read on that tick, in the next update), the loaded belts round it read again with it (its feeders and what it feeds, an
underground's other end, those within 7.5 tiles), a removed one's lanes leave (`dl`) in the next update, and a loaded
belt under a new one whose entity is gone is dropped (a fast-replace raises nothing for the old belt). Up to 2,400 belt
units a tick (`belt_sim.built_units`); the rest the next tick or the round's queue. Before, a new belt waited for the
round's start, any scan in progress and a scan of its own, each reading at most two chunks a tick whose lists had
expired (empty ones too): offline (the mod in Lua against the fake API, a belt built every 257 ticks), at a belt item
distance of 320 a new belt's `lm` came 9-200 ticks after it was built (half of them past 55), at 640 up to 550, and the
line it extended stood in Zenith meanwhile; on, 1-6 ticks at both, its read on the build's tick. Also on with it: a belt
loaded again after an event reads its lines' lengths again (a belt turned into a curve kept its straight lengths for the
catch-up and the packed checks). `/f3d-perf mined_tell` (on; off: as before, K22): what a player-less character mines
(a headless server; Factorio raises no event then) is told to what listens, as on_player_mined_entity does for a
player, so the belt simulation drops a mined belt's lanes the next tick and reads the belts round it; before, they
stayed until a check of that belt came round (seconds for a belt nothing watched) and its neighbours were never read
again for it.
`/f3d-perf zenith_join` and `/f3d-perf no_crash_site` (on; off: as before, L13): the player who joins with this
Zenith's Factorio takes over its character, and freeplay's crash site stays away from a world the bridge played before
anyone joined it (see "A world made in Zenith, joined from Factorio" above).
`/f3d-bs lane_next` (on; off: as before, E31): each lane's `lm` next says whether that lane leads out of what is sent,
from the belt its own items go on into (a splitter's output lanes each by their half's belt, found by where they end;
an underground entrance's hidden lines by its exit), and is sent again, with the lane's items read on that tick, when
that changes: when the belt it feeds loads (no longer negative) and when that belt leaves the square (negative, in the
update whose `dl` says so). A lane read twice in one tick sends its meta with the second read too, and reloads a round
didn't get to wait for the next round. Each drift check, lane leading out and watched belt checked also looks at its
lanes' next against what the client was told (counted in `/f3d-bs counts` as `next_fix`; `next_sent` counts the
changes sent where they happened). Before (the second PC, at the end of the owner's bus west of -62,-26): a belt
loading read its feeders' lanes again without their meta, so their -1 stayed though their next was sent (first loads
chain at most 4 rings out, so a line going outwards had every fourth ring loaded before its next, and the square's edge
did the same at every step walked); a belt leaving had its feeders' -1 sent only with the next round's reload, the
lanes saying 0 meanwhile with nothing after them (the client stopped their front items at the end: jumps); a reload
after a catch-up's read of the same lane in the tick lost its `lm` (a curve straightened by a belt built behind it kept
its curve in Zenith); a splitter with one half's belt not loaded had all four output lanes -1. Offline only (the mod in
Lua against the fake API, test_bridge.py's E31 section): not yet run against real Factorio.

`/f3d-bs ins_driven` (off until measured live; off: as before, the owner's idea): a belt watched for its inserters
alone (an inserter's pickup or drop belt, the belt behind a pickup belt: not a drill's drop belt, a splitter, a loader
or a loader's neighbour, nor a belt with a circuit connection, which keep their watch) gets no look every update. When
an inserter's own check (every update, its hand's count; the bridge's reads, not inserters.lua's `ie`, so the same on
every peer) finds the hand fuller, its pickup belt and the belt behind are read, and when it finds it emptier, its drop
belt is read. "Read" here means: each lane in full, except a lane holding items that stands as its last read left it, plus
the belts they feed as far as an item can have gone since the hand's check before. Then the belt is watched as before
for `ins_window` updates (20; 0: not) or until it settles, so the reads while the hole closes up and the settled read
still come; Zenith's packed-lane lattice takes a lane's motion and phase from those reads. Such belts get drift checks
(`pc`) as unwatched ones do. An inserter at one is checked every update, not backed off. `/f3d-bs ins_ho` (on; only
under `ins_driven`): a put by an inserter within the detail radius of the focus, for a client whose hello says `ie` and
`ho`, isn't read at all: the client got the item itself (`ie` PLACED). Needs `inputs_first`; off under `checkpoints`.
`/f3d-bs counts` shows `ins_takes`, `ins_puts`, `ins_told`, `ins_reads`, `ins_window`. Measured offline only, on four
line-end scenes (tools/belt_line_end.py, in which every belt is an inserter's; tests/belt_bs_replay.gd `--ie-wire=0`
and tools/belt_jumps.py): the bridge's belt work 30-39 -> 14-24 units a tick (39-54% less), lane reads 53-71 -> 14-28 a
second; the client's simulation by id 99.86-100% (99.99-100% off), the game's items drawn as often (98.8-99.6%), phantoms
0.06-0.14% -> 0.15-0.21%. Without the window (`ins_window 0`) the work fell 62-73% but the lattice drew pickup belts
from the read just after a take (the hole still open): 0.5-0.7 points fewer items seen. On the owner's base the share
of the belt watch on inserters' belts is unknown: measure there before turning it on (`tools/belt_truth.py`,
`tools/live_check.py`'s belt sections, `/f3d-profile`'s `bs.watch` and `bs.actor` at -62,-26).
`/f3d-bs quiet_pc` (on; off: as before, every unwatched lane drift-checked each turn, about every 32 updates near, 64
and 128 further out): an unwatched belt whose drift checks keep agreeing, nothing touching it, has each next check twice
as far off, up to `/f3d-bs quiet_pc_max` ticks (3600, a minute, near and far: the owner's safety limit; 0: every turn).
Any touch puts it back to every turn: a full read of one of its lanes (a `bre`, a packed run's read, a tail, a settle
read, a reload after building, mining or rotating near it), a watched belt behind it that changed or was put on (as
far as its tails reach, read or not), a wired belt behind it switched on or off, a splitter behind it set again (pasted,
its window closed, Zenith's own screen). Kept in each belt's record in storage, by game.tick: the same on every peer.
Offline (two 10-minute quiet 70-belt turbo lines, flowing and stop-and-go, no rereads answered): drift checks' numbers
125,360 -> 8,100 (94% fewer), the bridge's belt work 1.05 M -> 0.70 M and 0.60 M units (33% and 43% less), the client
exactly the game's (100.00% in place, 0 items off) both ways. `/f3d-bs reads` says why lanes were read in full since
loading, by cause, watched belts' and the rest's (`load`, `reload`, `next`, `exits`, `catch`, `run`, `tail`, `settle`,
`settled`, `watched`, `asked`, `ins`, `edge`), with the drift checks made (`pc`), passed over (`pc_quiet`) and the
belts woken; the same counts are in `/f3d-bs counts` as `rw_<cause>` and `ru_<cause>`.
`/f3d-bs two_call_full <N>` (default `16`; `4` before, `1` or `off` checks all four properties every time):
how many `two_call` checks pass before a watched lane gets a full 4-call check of its count and back item too.
`/f3d-bs settled_flow_only` (on; `off` restores re-reading every settled lane): skips the redundant `settled`
re-read when a lane's resting state was already sent by `sl` (`rec[14]`), still sending the settle read (and its
surrounding lanes) when `skip_flow` or `edge_walls` moved the lane without sending `sl`.
`/f3d-bs` main-bus scan/slice controls (all default on; `off` restores legacy behaviour): `scan_step_wide` (`true`;
`off` restores `r/32` scan step), `scan_step_min` (`12`), `drop_margin` (`16`), `take_slice` (`true`),
`load_budget` (`true`), and `edge_budget` (`true`).
`dec_distance` (on): Zenith's hello says how far it draws decoratives (`dd`, Settings > Graphics > Decorative distance,
320 under a screenshot's full detail), and a chunk's decoratives are sent only while the chunk is within that and 64
tiles of the square's middle; the rest are held and sent once the middle brings them inside or the distance grows. At
view distance 50 that leaves out most chunks' decoratives (a fifth to a third of a snapshot's work and bytes). A bridge
before it, or the switch off, sends every chunk's. `chart_same` (on): every minimap or map chart carries a stamp of what
its picture was made from (the chunk's change and entity counts, the resolution); Zenith names the stamps of the
pictures it holds when it asks again (every 5 s for the minimap), and an unchanged chunk is answered `same` with only
its live parts (pollution, signals, robots), not its picture; the bridge keeps a picture until something changed in
the chunk, not 30 s. Old clients get pictures as before.

Three switches for the ninth play-test list's delays, each on (off: as before). `status_near`: Factorio's warnings
over a turret out of ammo, a machine out of fuel and a drill with nothing left to mine (its resources-depleted icon)
round the focus come from the once-a-second power read, as the unplugged icon has since J5, not only from the alerts'
pass (every 10-40 s, several seconds long on a big base); a turret or burner built or removed is read again the next
tick, and after the character moves items (a machine screen's slots, Ctrl+click, Z) the buildings in its reach are
read again 2 and 20 ticks later. `mined_now`: whatever the character finishes mining is said at once (`mnd`: gone or
not, the items it got), outside the reliable outbox where the `del` waits behind chunk snapshots, and the inventory is
sent then too; Zenith takes the entity away and flies the items to the character on it. `put_lanes`: a belt the
character puts items on or takes them off (Z, Ctrl+click) has its lanes read in the next belt update, as Zenith's own
`bre` asks, instead of waiting for the lane's drift check (every 32 updates, several seconds).

`/f3d-perf drop_put` (on; the owner: "holding Z on a belt to place items takes a while to show up"): an item Zenith's
Z puts on a belt is told at once as an inserter's put is (`ie` kind 6 with no inserter, unit 0: its lane, place and
unique id; for a client whose hello says `ho`), and the belt's drift checks come every turn again (`quiet_pc`'s
wake), on top of `put_lanes`' read, which can wait behind other asked lanes. Factorio's own Z onto a belt in the game
window (hybrid) wakes the belt and reads its lanes, if Factorio raises `on_player_dropped_item_into_entity` for a
belt (not checked). Off: the lanes' read alone, as before. Zenith's side, `--belt-drop-glide` (on; `--belt-drop-glide=off`: static drop card as before) glides hand-dropped items along the lane immediately rather than holding them static until `put`, and `--belt-drop-show-now` (on; off: as before): the dropped item shows at once, standing where it lands on the nearest lane drawn, until the drawn clock
(about half a second behind the game) reaches the bridge's put; the simulated item shows there from then. One the
bridge doesn't confirm (out of reach, the belt full there, an older bridge, `--inserter-handoff=off`) goes after
1.5 s.

`/f3d-perf belt_pickup` (on; issue #18): F takes the items on belts too, as Factorio's "Pick up items" does: every item
within the character's item pickup distance (plus half a tile, measured from the character's middle to each item), on
the ground or on a belt's visible lanes, the nearest first, up to 16 a tick (all in range in practice). An item on a belt
goes into the character as its stack (quality and freshness kept) and off its lane; the lane is read before and after,
so what the bridge says is what the game did, and anything the lane wouldn't give up comes back out of the character.
It says what it took at once (`pku`): Zenith hides an item taken off the ground, takes one off its simulated belt on the
game's tick through the same take as an inserter's pick (belt_items.gd `ie`, with no inserter; so with
`--inserter-handoff=off` it leaves only with the lane's next read), and flies each kind to the character with the item's
own pick sound. The lanes are read again in the next belt update (`put_lanes`) and the inventory is sent at once, at most
every 6 ticks while F keeps taking. Off: the ground only, two a tick, as before.
`/f3d-perf pickup_stop` (on; the owner: F "seems to pickup for almost a second after you let go"): Zenith sends
`pickup_stop` as F is let go (also over a window, and when a text box takes the keyboard) and the bridge ends the
pickup then; off, the stop is ignored and a pickup runs on 30 ticks after the last `pickup` (sent every 0.15 s while F
is held), as before and as for clients that never send it. Zenith's side: `--pickup-stop=off` sends no stop. And
`--pickup-hide-now=off`: a belt item F took left the drawn belt only when the drawn clock, about half a second behind
the game, reached the take (its icon already flying); on (the default) the items a `pku` names, by the game's ids, hide
in the belt layer's next job, and a packed lane the lattice draws gets the take's hole from the drawn tick (where the
item was then) instead of the take's own tick.
One for the tenth list, on (off: the chests alone). `alt_machines`: while the client has Alt-mode on, the machines
whose prototype has module slots (assemblers, furnaces, silos, drills, labs, beacons) and the labs in the focus square
are read in the chests' rounds (J6) for the modules and science packs Alt-mode draws over them (`am`, K1, K2): 3 work
units a machine under the work budget, after the chests, each round sending only those that changed. Nothing is read
while Alt-mode is off.
`alt_ammo_fuel` (K1's leftover), on: with `alt_machines`, the ammo turrets and locomotives in the focus square are read
in the same rounds for the ammo and fuel Alt-mode draws over them, one icon a filled slot, where Factorio's prototypes
put them (2.1's gun turret lists its ammo a quarter tile up, its locomotive its fuel three a row; a turret without an
entry, as Space Age's rocket and railgun turrets, gets Factorio's defaults). Off: machines and labs alone, as before.
Cargo wagons (owner: "i do want to see items in cargo wagons"): the same rounds read each wagon's four most-stacked kinds
(most first, no counts, as a chest's) and the client draws them in one row over it, following it as it moves; a
locomotive's fuel is off by default (the client's `--loco-fuel-icons=on` sends `lf` 1 with `altc` and draws it again).
The client's `--alt-ammo-fuel=off` draws none of the three whatever the bridge sends. Fluid wagons show nothing.
`/f3d-perf` megabase UPS controls (all default on; `off` restores old behaviour): `mover_move_scan`,
`st_working_slice`, `splitter_throttle`, `inserter_look_budget`, `fluids_budget`, and `alt_cadence`.
`/f3d-perf prio_cap` (on): the end-of-serve `transport.flush_priority` (`flush_end`) counts what `transport.flush`
already sent that tick, so one tick sends at most the priority budget (`max(f3d-bytes-per-tick, 32 KB)`); off: each
starts its own budget (up to about 64 KB in one tick, past what Windows keeps unread), as before.
Bridge UPS round, whole-base jobs (all default on; `off` restores the old behaviour): `/f3d-perf map_trains_slice`: the
map's trains (`mtr`) are read in a job under the work budget, a train at a time from the list the ask took (the packet
handler only starts the pass, an ask while it runs waits for it), and `mtr` goes when the pass ends; the alerts' train
scan (out of fuel, no path) reads 40 trains a tick. Off: every carriage in the packet handler, every train in one tick.
`/f3d-perf alerts_topk`: `al` picks each kind's 40 nearest in one pass instead of sorting the whole list, and keeps the
pick while the scan's list, the focus and the near square are the same (a shown entity gone makes it again; a count may
include an unshown entity removed since the scan, until the next one); the alerts' pass also stops inside a chunk at
its per-tick allowance and goes on there the next tick (a chunk dense with machines or pipes was read whole). Off: every
list sorted each time, each chunk read whole. `/f3d-perf
events_enqueue`: an event about a watched entity (built, marked or unmarked for deconstruction or upgrade, flipped,
rotated in the game, recoloured) tells the listeners and queues the entity (once, by unit number); its record and the
reads round it (wires, neighbouring belts and pipes, decoratives) go from on_tick, nearest the focus first, two work
units each (at least 8 a tick); one removed while queued has its record sent before its `del`. `/f3d-status` and `wb`
list the queue as `events`. Off: all of it in the event, as before.
`/f3d-perf gc_pace` (on): the bridge's Lua garbage collector stopped and its work done once a tick after the bridge's own
(`gc_pace.lua`, `gc` in `/f3d-profile`), in small steps up to a budget of work (twice what was allocated) and of memory
freed (twice that, 1 MB at least), a cycle starting once the heap is twice what is live, with a live sentinel so Lua 5.2's sweep never starts by freeing everything the cycle
threw away at once; a heap over 4 times the paced base (or 512 MB) restarts the collector until the next tick paces it again (checked each tick, after packets and commands; `rescues` in `/f3d-status`); off: Lua's own collector restarted, its steps landing in whichever module allocates, as before.
`/f3d-perf gc_lean` (on): eliminates per-loop inline closures, caches valid `LuaEntity`/`LuaInventory`/`LuaTransportLine` handles across ticks, guards inventory scans with `is_empty()`, throttles steady-focus `find_entities_filtered` rescans, and yields to `budget.left()` across `movers`, `alerts`, `inserters`, `fluids_power`, and `alt_mode`; off: restores legacy per-tick scans and closures.
`/f3d-bs watch_lean` (on): a lane's methods (`get_item_count`, `get_item_position`, `get_detailed_contents`,
`get_contents`) read off the line once and kept with it (reading a method off a game object makes a new function, 88
bytes, each time); off: read again at every call, as before. `/f3d-bs scan_incremental` (on): the belt square's scan
flattened over as many ticks as its units allow (about 1 us a belt), into the arrays of the scan before last, taken the
tick after; the scan at most half a tick's units once something is loaded; off: flattened and taken on one tick, as
before (16-27 ms on Zenith Test while walking).
One for the eleventh list, on (off: as before). `research_chain` (L12): Zenith's `research` of a technology whose prerequisites aren't all researched or queued queues the missing ones first, all the way down, each after its own (by order), then the technology, as Factorio's technology screen does: 2.1.24's LuaForce.add_research alone refuses it, and refuses a trigger technology and an eighth in the queue (measured in real headless 2.1.24). When one of the missing is a trigger technology nothing is queued and the bridge says which; when the queue can't hold them all, what it queued comes off again ("Research queue full"). Off: add_research alone, as before.

Two more for the eleventh list, on. `fluid_icons` (L10): a crafting machine with a fluid recipe carries its connections and
the fluid each takes or gives (2.1 makes its fluid storages from the recipe, each filtered to its fluid: an oil refinery
on basic oil processing has two) in its record and in `aiu` (`fc`), for the arrows and fluid icons Factorio draws on a
machine hovered or in Alt-mode; off: none sent, the client draws the prototype's arrows without icons. `pipe_alerts`
(L11): a pipeline over Factorio's extent limit (UtilityConstants' default_pipeline_extent, 320 tiles; status
pipeline_overextended on every pipe of it) is an alert, `al` `pipeline`, one entity a fluid segment (the one nearest the
line 320 tiles in from the segment's far edge, where a pump would split it, as the icon stood in the owner's video): the
alerts' pass reads pipes, pipes to ground and storage tanks too (a quarter of a machine's cost each), and a pipe-type
entity or pump built, removed or turned on the focus surface has the pipelines round it read the tick after (`al` at
once when that changes). Off: no such alert, the pass as before.

One for the twelfth list, on. `under_clear` (M2): an underground belt or pipe-to-ground the character builds that
completes a pair mines what lies between its ends into the character, as Factorio's player build does (its tips and
tricks, "Fast replace belt & underground belt": "Any belts in between the entrance and exit of the underground belt
will be mined automatically. This fast replace feature also applies to pipe and pipe-to-ground"): only a plain run,
every tile between a belt going the pair's way, straight and fed by nothing from the side (a pipe connected to nothing
off the line), all of them or none (a gap, a curve, a belt the other way, a side-load, a splitter or a ghost keeps them;
building over another underground, an upgrade, never clears). A script's create_entity doesn't do it, with or without
`character` (measured in 2.1.24), so the bridge mines them itself (building.lua clear_between): each with what it
holds into the character, forced (what doesn't fit spilled, as Factorio spills it), said at once (`mnd`, then the
reliable `del`), the inventory sent once after them. And an underground fast-replacing a belt (a pipe-to-ground a
pipe) is built with `character`, so the belt and the items on it go to the character, where `spill = false` deleted the
items. Off: both as before (the belts between stay, a replaced end's items gone). Hybrid single-player with a free
cursor builds as the player, where Factorio does it itself. Ghosts and blueprints are the game's (unchanged).
`python tools/live_check.py --only underclear` checks it against the real game. The client marks the belts that will go
and hides them as the build is sent (`--underground-clear=off`, below in the controls). A drag that places both ends
hides them with the exit's build too, though the entrance's `add` hasn't come yet: the pieces just sent count as
standing until the world has them or the game has moved on without them, for the build and for the cursor's marks and
its entrance or exit model (`--underground-clear-sent=off`: only what the world has, so such a run goes when the
game's `mnd` comes, a tick later, as before).

Two for the thirteenth list's vehicles, on. `fast_take` (N2): an empty hand's Ctrl+click never takes an entity's fuel.
In 2.1 defines.inventory.fuel and chest are both 1, and a locomotive's and a burner drill's get_output_inventory is
their fuel slot (read in 2.1.24), so the bridge checks each inventory against the entity's own fuel inventory and falls
back by type (a chest's, a car's or spidertron's trunk, a wagon's cargo); off: as before, when a locomotive, boiler,
burner inserter or burner drill gave up its fuel. `vehicle_ammo` (N3): in an armed vehicle `me` `sh` and "Out of ammo"
follow the vehicle's selected gun's ammo (the game fires it for the driver); off: the character's, as before. A
vehicle's shots come in `ts` as before (turrets.gd draws them), not as `shot`. `--only vehitems` checks both.

A pipe's end after one beside it is mined, on. `mined_neighbours`: what the bridge's player-less character mines (a
headless server's; Factorio raises no event for it) has the pipes and belts beside it read again the tick after and
sent (`upd`), as a player's mining has them (tracker.lua neighbours_change): the pipe left at a run's end becomes its
ending piece, a belt beside a mined one its new shape. Off: as before, their records kept the side to what was mined
(the run's last pipe drawn as a straight, open at its end in FUE5's kit, until something else changed it). The client
also takes the side towards a mined pipe off its neighbours the moment the `mnd` or `del` comes, for any bridge
(world.gd `_unlink_pipes`); `--pipe-end=old`: its neighbours wait for the bridge, as before.

Enemies seeing the character, on. `enemy_sight`: a headless server's character has no player, and in 2.1.24 a nest's
own idle biters ignored it from 50 tiles to 1 until it shot (loose biters and worms saw it), where a real player's
woke them. Every half second the bridge does what the engine was measured doing for a real player's character
(enemy_sight.lua): a sleeping enemy unit (no distraction, no attack of its own, in no unit group) within its own
prototype's vision distance of such a character gets the distraction a sighting gives (attack the character,
`by_enemy`), and so does every sleeping unit of its nest (the units whose own spawner is in the cluster, its spawner and
the spawners within 15 tiles of it; a neighbouring nest's units stay asleep, and a new unit of a nest woken lately is
given alone); while the character stands they are kept on it, each for its own hold (spread by unit number: about half
gone by 8-10 s, the bridge's re-giving over by 15 s, then the engine's own tail keeps a few on it, as measured for a real
player's), and while it moves every one of them within its vision of it is kept on it, with no
give-up distance. Out of vision nothing wakes; worms need nothing (they shoot it on their own). Nothing is done for a
character with a player (hybrid single-player, a claimed L13 player: the engine sees those), on a hub, on a
peaceful or no-enemies surface. Cost: one `find_units` over the largest unit vision's square every 30 ticks, and one spawner
search plus one more `find_units` per nest woken (at most 4 a pass). Off: nothing done, as before.
In a vehicle, on: `enemy_sight_vehicle`. A real player driving or riding a car, tank or spidertron near a nest is
attacked in it; for the player-less character in one the same vision, nest wake, holds and chase are counted from the
vehicle and the vehicle is the target. Getting in or out, the units it woke that are on the old target are given the
new one. Nothing for a train (rolling stock is not a military target in Factorio's prototypes, and biters leave a
passing train alone), a vehicle that isn't destructible, or one a real player shares (the engine's). Off
(`/f3d-perf enemy_sight_vehicle off`): nothing done in any vehicle, as before.
`python tools/live_check.py --only enemysightfix` checks both against the real game, the car by putting the character
in one (fresh map only: it clears the enemies round its spot and runs the game fast for up to 5 minutes, twice).

Bridge responsiveness switches (all on by default, off: as before):
- `flush_end`: `transport.flush()` stays at step 1 of `STEPS_FAST` (draining bulk `outbox`) while `STEPS_FAST` moves
  `world`..`inserters` (`world`, `movers`, `robots`, `belt_items`, `belt_lanes`, `ground_items`, `fluids_power`,
  `inserters`) ahead of `map`/`lod`..`space` scans and calls `transport.flush_priority()` at the end of `serve()` to
  drain `outbox_prio` (interactive replies and unblocked deltas) onto the wire the same tick (0-tick bridge lag instead
  of 1). Off: runs `STEPS` and flushes only at step 1 via `transport.flush()`, as before.
- `near_first`: prioritises work nearest the player's focus across per-tick lists — inserter update buckets, tracked
  robots, and chunk snapshot slices (`requeue_slices` keeps queued chunks nearest focus ahead of outer chunks after
  jumps or subscribes). Off: scans/queues without near-first ordering, as before.
- `near_rate`: keeps entities and chunk snapshot progress inside the focus near-bubble (~48–64 tiles) at full cadence
  under load-shedding `rate` levels and tight work `budget`, scaling back only outer chunks. Off: throttles the whole
  focus square together, as before.
- `nack_ring`: keeps the last 256 flushed reliable packets (`NACK_RING_SIZE = 256`, cleared on `hello`/reset) so client
  `nack` requests immediately retransmit any matching `r` in place with its original sequence number, falling back to
  chunk `c` requeue only for gaps older than 256 frames. Off: does not retain sent packets in the ring and requeues
  `c` chunks directly, as before.

### Oil, resources and pipelines (the eleventh list)

- Hovering a resource (L6) shows its amount now (`hinfo` `ra`; the record's until the bridge answers), an infinite
  one's yield (its amount over its normal amount: crude oil's 100% at 300,000), the fluid mining it needs and the drills
  that mine it (Factoriopedia's page). On the map (zoomed out) a resource patch under the mouse is outlined in white and
  the entity info shows its total, an oil field's combined yield ("Crude oil combined yield 292%"), as Factorio's map
  view: the bridge sums the patch the tick it is asked (`rpatch`; resources within the prototype's
  resource_patch_search_radius of each other, 3 tiles, crude oil 12; at most 10,000 of them, about 5 microseconds each in
  2.1.24, then "at least"), once the mouse has rested 0.12 s on a tile outside the patch shown. `--map-resource-info=off`:
  none on the map.
- A held drill (L8) is red where its mining area holds no resource it mines ("Pumpjack can only be built on resources",
  "... cannot mine this resource" over ore), the well it would pump is outlined green and the wells round the cursor
  white (Factorio's highlight for crude oil and Space Age's fluid resources); its output arrow shows (an old bridge's `fo`
  hid every drill's), and no arrow in a pumpjack's middle. `--resource-hints=off`: as before. Over uranium ore (any
  resource needing fluid to be mined: the bridge's `rf`) it follows Factorio 2.1.24's rule: an electric drill (a fluid
  input) is red with "Uranium mining not researched." until the force can mine with fluid (`cinfo` mwf; even with other
  ore beside it), and the bridge refuses it in the same words; a burner drill can't mine it ("... cannot mine this
  resource" over uranium alone). `--fluid-mining-hints=off`: uranium counts as any ore in the preview, as before (the
  game still refuses it). A held pipe's preview
  joins the pipes beside it, a pipe to ground facing it and a machine's connection pointing at its tile (it was always the
  lone pipe); `--held-pipe-joins=off`: the lone pipe. FUE5's pumpjack is mirrored across its diagonal
  (`tools/models/fue5_pumpjack.py`), its outlet at Factorio's output (FUE5's was the mirror image); no switch (the old
  file is in git's history).
- A crafting machine's connections (L10) show the fluid each takes or gives, an icon on the connection's tile beside its
  arrow, hovered and in Alt-mode (with "Show machine arrows"); from the record's `fc`. `--fluid-icons=off`: the
  prototype's arrows without icons.
- A pipeline over the extent limit (L11): Factorio's red fluid icon blinks over one of its entities and the alert bar
  says "Pipeline has been overextended."; hovering a pipe, pipe to ground or storage tank shows "Pipeline overextended"
  (its status, red) and "Pipeline extent: 333/320" (`hinfo` `pl`, `ox`). `/f3d-perf pipe_alerts off`: no alert.
- Factorio 2.1's fluid pipeline visualization (N9, `scripts/player/pipeline_marks.gd`): hovering a pipe, pipe to ground
  or storage tank marks each joint of its pipeline with Factorio's both-ways chevron (and an underground pair's run with
  its dashes; the pictures from the install's core/graphics/fluid-visualization/, plain drawn ones without it), tinted
  to the fluid in it, white when empty, red when the pipeline is overextended (the hovered pipe's `hinfo` `ox`, or an
  `al` `pipeline` alert on one of its entities); hovering a pump, boiler or machine, the pipelines on its connections;
  with a fluid entity held, in Alt-mode, every pipeline within two chunks of the cursor (a frame where nothing changed
  costs only a look at the chunks it read). The pipeline is found in the client from the records (`pc`, underground pairs, a tank's `eprops`
  fluid boxes), stopping at pumps and machines, at most 4,000 entities, a slice a frame. Settings > Interface >
  Visualization: "Show fluid pipeline visualization" and "Show fluid pipeline visualization when selected" (Factorio's
  names, on by default, read from its config.ini as the other interface settings). `--pipeline-vis=off`: nothing drawn,
  as before. The mock's line at -24..-13, -17.5 stands for an overextended one (`pl` [340, 320], `ox`, its alert).
- The alert sound: Factorio's beep (its utility sound alert_destroyed, from the install, at half volume) when the
  bridge's alerts gain something destroyed (Factorio's changelog: the beep "only when something is destroyed, not by
  something damaged"). A turret running out of ammunition makes no sound (the owner's choice; Factorio's own beeps once,
  "only sounds once right when the ammo is used up"): `--alert-sounds=ammo` brings that beep back as before. One beep
  however many at once, none for the alerts already there when Zenith joins, none for a kind ticked Muted or Disabled
  in the Alerts configuration (Muted did nothing before). `--alert-sounds=off`: silent, as before. Factorio's own repeat while buildings keep falling isn't measured: here every update with a new one beeps,
  a second apart at most.
- Alerts on the minimap and the map view: the alert bar's alerts (the kinds the bar shows, its 40 nearest of each
  kind, the ones on the surface shown) drawn as Factorio's own alert icons at the minimap's and the map view's tag size,
  destroyed over attack over turret fire over the rest, blinking as the icons over the entities do (a 1 s period, on
  55%; the steady kinds steady). Client only, from the bridge's `al`: nothing more is asked of the bridge.
  `--minimap-alerts=off`: neither view draws them, as before.

### Health bars and the hidden interface

The health bars over damaged entities are part of the interface: not drawn while it is hidden (F11, an add-on's
`api.view.hide_interface` such as the Cinematic camera's clean shot, `--clean-shot`), back with it.
`--health-bars=always` draws them even with the interface hidden (the old behaviour); `--health-bars=off` never
draws them (filming with the interface showing); `--health-bars=auto` is the default.

### The client's UDP socket (lost datagrams)

Every datagram the bridge sends a client whose hello says `dq` (Zenith does) ends with a `dg` line numbering
it (docs/PROTOCOL.md, Transport), so the client counts the datagrams the OS dropped: `Bridge.loss`
(`datagrams`, `lost`, `unnumbered`), the debug line's "datagrams lost", and `--udp-trace=<file>` (a JSON line
per datagram read: when, its number, bytes, tick, message types). With `/f3d-profile trace` on, the bridge
logs every datagram too (`f3ddg <tick> <n> <bytes> <types>`), and `tools/udp_loss_check.py --bridge-log
factorio-current.log --client udp.jsonl [--stream stream.jsonl]` reports the loss by message type, size and
burst position, the ticks' bursts, and the `bs` updates' tick gaps split by the announced period `p`.

What that found (the udp round, docs/SESSION-LOG.md): the "18% of datagrams lost" at -62,-26 read off the
`bs` updates' 12-tick gaps was mostly the bridge's rate level 3 pacing `bs` at p=12 (148 of 177 12-tick gaps
announced; `rate.lua`). The real loss was 3.3% of datagrams in an 8-minute run there (128 of 3,897) and 18%
at -272,-14 (730 of 4,018) with another agent's Python tools running beside the game: not the tick's burst
(0 of the lost came when their tick had sent over 64 KB; 99% were their tick's only datagram) but the client's
I/O thread going unscheduled: at normal priority on a 4-core PC with the game, the belt jobs and the parsing
thread, it stalled 49 / 89 times for over 100 ms (up to 0.6 / 1.3 s), and Windows keeps 64 KB of unread
datagrams per socket (Godot's `PacketPeerUDP.bind` size is only Godot's own ring; the OS buffer stays the
default, `tests/udp_burst_test.gd`): every stall filled it (the drain after it read 44-135 KB) and lost all
that came until the next read, 1-48 consecutive ticks' datagrams, every message type alike (`bs` parts and
whole updates, `ih`, `mv`, `me`, chunks, ...). `OS.delay_usec(1000)`, the thread's sleep, is 2 ms on Windows.

The fix, in the C++ extension (client/native, `UdpSocketNative`) and bridge.gd:
- `--udp-socket=native|godot` (native, the default when the extension is loaded): a socket whose OS
  receive buffer is `--udp-rcvbuf=<bytes>` (8 MB: tens of seconds of the bridge's traffic), read with
  `wait()` (select) so the I/O thread wakes as a datagram arrives. `godot`: PacketPeerUDP as before.
- `--native-decode=off`: the bridge's binary frames (`bs`, `bfar`, `chunk`, `ents`, `st`, `ih`, `mv`, `rb`) are unpacked by `WireDecodeNative` (C++, same results as `wire_decode.gd`; `tests/wire_decode_native_test.gd` compares both); `off` (or no extension) reads them in GDScript as before.
- `--udp-io-priority=high|normal` (high): the I/O thread at Thread.PRIORITY_HIGH, so an arrival gets it the CPU.
Measured live (one run each, the same harness): datagrams lost 128 of 3,897 (3.3%) -> 0 of 4,085 at -62,-26 and
730 of 4,018 (18%) -> 0 of 4,344 at -272,-14; `bs` updates lost whole 8 / 35 -> 0 / 0, parts missing 10 / 48 ->
1 / 1 (the capture's last update, cut by the stop); the I/O thread still went 50-540 ms without reading 93-106 times
a run (the game's own pauses count in that too) and the 8 MB held everything. Belts: visible / phantoms 96.1% /
2.6% -> 96.2% / 2.3% at -62,-26 (rate level 3 both times; the reference 96.2 / 1.9 is within the spread, still FAIL
there) and 97.3% / 1.0% -> 97.5% / 0.8% at -272,-14 (PASS both). The arms at -62,-26 (tools/inserter_check.py): the
drawn hand's moving error 0.37 -> 0.23 tile mean (p90 0.85 -> 0.43), swing coverage 74% -> 88%. The synthetic burst
(tests/udp_burst_test.gd --socket=native against a sender of 12 x 60 KB a tick back to back): 0 lost, against 3 of 6 x
30 KB with PacketPeerUDP.

### Update rates at the owner's belts (the belt-rate round)

Why the belts at -62,-26 sit at 96.1-96.3% visible / 1.9-2.6% phantoms under Hold 60 UPS (the target 97% / 2%)
while -272,-14 passes, measured live (tools/belt_view_check.py, `--record 60`, by day, 3-4 runs a cell at -62,-26; the
bridge profiled with `/f3d-profile`, the level held with `/f3d-rate <l> hold`, the `bs` period capped with
`/f3d-bs period_max 6`; the run folders under E:\Zenith-scratch\rate):

- **The 12-tick `bs` period is not the gap.** With `bs` at 12 ticks (rate level 3, as the governor reaches it in the
  scored window): live visible 96.1-96.3%, phantoms 1.9-2.3% (4 runs). With `bs` held at 6 ticks at level 3
  (`period_max 6`): 96.2-96.3% / 1.7-2.4% (3 runs). At level 2 held (6 ticks, the tier-3 jobs at their full rate):
  96.3% / 1.8%. Hold 60 UPS off (level 0, everything at its full rate): 96.4% / 1.6%. Visible is the same in every
  cell; phantoms lean a few tenths towards the faster updates, inside the spot's spread (1.6-2.6% over all runs).
  The remaining 0.7-0.9% of visible is the belt simulation's own accuracy at this bus (the splitter balancers: the
  replay diagnostic is 76%); -272,-14 passes at level 2 (97.6% / 0.8%, 6-tick updates there either way).
- **What the 12 ticks cost and save.** At level 3 `belt_items` 4.0-4.7 ms a tick at 12 ticks against 5.3-6.0 at 6
  (`bs.watch` 2.0-2.3 -> 3.0-3.2, `bs.bre` 0.8-0.9 either way), the bridge whole 8.7-9.8 against 10.0-11.6 ms,
  UPS 47.9-48.6 against 46.3-48.5 while scored. Level 2 held: the bridge 12.3 ms (movers 0.77 against 0.3-0.6,
  planets 0.9, tracker 0.24), UPS 45.1. Hold 60 UPS off: 16.8 ms (movers 2.1, transport 3.0, world 1.2, map 1.0 +
  0.9), UPS 36.3. The stretch goes (`period_max` 6 by default): over all the runs, 6-tick updates kept phantoms
  under the 2% gate in 4 of 5 (1.7, 1.7, 1.7, 1.8, 2.4) where 12-tick ones did in 1 of 6 (1.9, 2.1, 2.3, 2.3, 2.3,
  2.6), for 1-2.5 ms a tick of bridge and about 1 UPS here; `period_max 0` is the knob for a server that needs them.
- **Why the game runs at 46-48 UPS while scored.** The game's own update on Zenith Test is ~2.9 ms a tick (the
  server alone at `game.speed` 8 ran 345 UPS, its main thread 0.84 of a core). With the client at -62,-26 the
  bridge's Lua is 8.7-11.6 ms a tick (steady, after the first load: `bs.watch` 2-3.4, `bs.bre` 0.8-1.0, `transport`
  1.4-1.8 (the datagrams: about a millisecond each), `planets` 0.5-0.9, `alerts` 0.6, `map` + `map.strip` 1.0,
  `world` 0.5, `movers` 0.3-2.1 by level), Factorio's main thread 0.85-0.92 of a core (compute-bound, not starved:
  ~3 game + ~10 bridge + ~4 of its own round a modded tick), the client 1.9-2.2 cores and the machine's 4 cores
  87-91% busy. And the recording itself: record.py reads the square's belts over RCON every 60 ticks inside the
  game's tick, so every run shows 55-58 UPS in the 20 s before the recording and 45-49 while scored (-272,-14: 56
  -> 38). Without the recorder the game runs 55-60 at level 2-3 here, and holds 60 at ~8 ms of bridge (once `far`
  96 shrinks the square, ~100 s after joining; the scored window, 60-80 s in, sits on the ladder's way down).
- **What changed.** (1) The governor's ladder (ups_governor.gd STEPS) skips its `updates` steps (Moving belt items
  3000, 1500: `bfar` m, the belt cap): the client simulates its belts and the bridge's square ignores the cap
  (`full_area`), so they bought nothing and cost 5 s each before `far` 96 shrank the square; `--ups-updates-steps=on`
  takes them again (for a bridge with `/f3d-bs full_area off`). (2) The alerts' pass over the force's machines
  (alerts.lua, 0.6 ms a tick here: it fills its 600-tick interval on this save) is a rate job (`al`, tier 2): at
  levels 2 and 3 a pass starts 2 and 4 times less often (alerts show 20-40 s late instead of 10). (3) `/f3d-rate
  <0-3> hold` holds a level against the clients' `rate` commands until `/f3d-rate free` (measuring); `/f3d-bs
  period_max <ticks>` caps the `bs` period (6, the default: never stretched; 0: rate.lua's 12). After, with
  (1), (2) and 6 ticks: 96.3% / 1.7% and 96.3% / 1.7% at -62,-26 (before, the UDP round at 12 ticks: 96.1% / 2.6%
  and 96.2% / 2.3%), UPS 48.5 and 46.5 while scored (46.5 and 47.3), the bridge 10.0-11.6 ms a tick; 97.6% / 0.8%
  at -272,-14 (97.3-97.5% / 0.8-1.0%; level 2 there, 6-tick updates either way). Still FAIL at -62,-26 on visible.

### The belt gap at -62,-26 (the belt-accuracy round)

What the 3.7% of unseen game items (and the 1.7% phantoms) at -62,-26 were, from the belt-rate round's recorded
runs re-scored offline with every game item-tick and drawn record tagged (the same matching as section L):

- 1.99% of the game's item-ticks lie on recorded lanes past the screenshots' bounds: record.py records every belt
  whose collision box touches the recorded ground, so lanes along the edge reach up to a tile past it; the scorer
  counts their items but drops every drawn record outside the bounds before matching. 99.8% of them have a record
  of the right item within 0.15 tile at the game's place, outside the shot. A scoring artifact (the gate is the
  owner's): visible as gated 96.3%, inside the bounds 98.2%, counting those drawn right outside the shot 98.3%.
- 1.73% missed inside the bounds: 1.41% on lattice lanes (splitter lanes 0.73%: one item in ten there; straight
  0.30%, undergrounds 0.19%, curves 0.12%; a drawn slot within 0.15 tile but taken by another game item 1.03%,
  the nearest slot 0.15-0.3 tile off 0.37%), 0.33% on the lanes the simulation draws itself (one in seven of their
  items). Phantoms: lattice slots with no game item 1.39% of the drawn, the simulation's own records 0.35%
  (items taken meanwhile, items on another lane). Flat over the 20 recorded ticks, and mostly on lanes read long
  ago: the lattice's phase, not corrections.
- The phase (see `--belt-draw-lattice-world`, `--belt-draw-lattice-standing` above): with the game's own phase
  on every lattice lane the same dump scores 97.5% / 99.5% inside / 0.48% phantoms (the ceiling of phase fixes);
  the rest is the simulation's lanes that aren't full.

Measured with the two switches on, the same captures replayed offline (tests/belt_bs_replay.gd --every-tick with
`--belt-draw-dump`, scored as section L; scratch replay_score.py): -62,-26 96.42% visible / 98.34% inside / 1.68%
phantoms -> 97.11% / 99.08% / 0.99% (world all alone 96.78 / 1.22, standing obs alone 96.71 / 1.40); -272,-14
97.59% / 99.22% / 0.80% -> 98.10% / 99.75% / 0.37%. Live (Hold 60 UPS, `--record 60`, by day, 6-tick `bs`):
-62,-26 96.3% / 1.7% (the rate round's two 6-tick runs) -> 96.9% / 1.5%, 97.0% / 1.3%, 96.9% / 1.3% (three runs; inside
the bounds 98.2% -> 98.8-98.9%; the game at 46-49 UPS while scored, rate level 2-3; still FAIL on visible as gated: the gap left is the
2.0% past the bounds); -272,-14 97.6% / 0.8% -> 97.7% / 0.4% (inside 99.2% -> 99.7%), PASS. Run folders under
E:\Zenith-scratch\acc.

Found on the way: since de96093f every headless test preloading belt_items.gd (tests/belt_bs_replay.gd, so
belt_view_check's own replay, section 0) ran with belt_items.gd's statics unset (moment_hold.gd named the Bridge
autoload, a compile error outside the scene): the "replay diagnostic" of 74-76% at -62,-26 was that, not the
simulation (fixed: the autoload looked up by path). And on Godot 4.7 `hash(int)` changed, so every item's turn
drawn by the C++ paths differed from the GDScript paths' (tools/belt_draw_diff.py showed millions of differences
in the turn alone); `hash_int` follows 4.7's hash_one_uint64 now.

## Client controls

These are Zenith's built-in defaults: Factorio 2.0's, with Map on Tab (or M), Next weapon on C and Shoot
selected on Shift+Space as Wube's changelog has them since 2.0. With Factorio's `config.ini` found, Factorio's own keys replace them: the
ones you changed in Factorio's Settings → Controls, and Factorio's defaults for the rest (the `; ` lines
Factorio writes there, right for your Factorio version and keyboard layout), so both answer the same
keys (Settings → Controls → "Use the keys set in Factorio"; a binding changed in Zenith's Settings still
wins). Mouse bindings set in Factorio aren't used. Keys are matched with exactly their modifiers, so
Shift+Space doesn't also shoot at enemies, Ctrl+Keypad + doesn't grow the tile area, Ctrl+Shift+Z
doesn't undo and Ctrl+F (search) and Alt+F (the personal roboport) don't pick up (`--pickup-exact=off`: F
picks up with any modifier held too, as before; F pressed under Ctrl or Alt starts picking only when pressed
again after they are let go); G, Factorio 2.1's key for both the rail layer and getting in (its alternative), changes the
rail layer with rails in hand and gets in otherwise.
Following Factorio 2.1 takes away keys Zenith 0.2.2 had beyond Factorio's: 2.1's default lines leave the
arrow keys, the console's alternative and Keypad Enter unbound (and give getting in G as its alternative), so
the arrows don't walk or pan the map and `/` doesn't open the console. Settings → Controls → "Zenith 0.2.2's
keys" (saved; `--keys-defaults=old` turns it on for one run) brings back exactly 0.2.2's keys: the built-in
defaults Map on M, Next weapon on Tab and Shoot selected on C (1.1's), and of `config.ini` only the controls
you changed in Factorio, not its `; ` default lines, so the arrows walk and pan the map, `/` opens the console
and Keypad Enter gets in again. "Copy keys from Factorio" follows it, and its message says which it used.
Zenith finds `config.ini` where the install's `config-path.cfg` says (`%APPDATA%\Factorio\config` for
Steam and the installer, the install's own `config` folder for the zip, or a folder of your own), and
reads it at start, when its window comes back from another (a key changed in Factorio meanwhile is
followed; `--factorio-keys-refresh=off`: at start only) and when the switch is turned. Coming back
looks only at the file's modified time (in the few seconds after config.ini was written it also compares
the text's length and hash, as a write in the same second leaves the time as it was); Zenith looks for the install again when Settings → Factorio
install or `--factorio=` changed, or (with none found) at most once a minute. Rebinding one
slot in Zenith leaves the other following Factorio's (saved as `default`). **Copy keys from Factorio**
(Settings → Controls, issue #26) looks for the install afresh, drops the bindings changed in Zenith for
every control Factorio has (each then follows Factorio's changed key, else Factorio's default),
switches "Use the keys set in Factorio" on and shows what was copied, what wasn't and why (mouse
buttons and the wheel, controller bindings, controls Zenith has no key for) and the file it read,
keys named as Factorio names them ("`", "Page Up", "Numpad +"). Zenith's own controls (camera, views)
keep theirs; the message lists any copied key one of them also has (camera tilt's Page Up and Page
Down, and in dev builds the debug line's F4 and the debug menu's Control + F12), as both then act.

| Input | Action |
|---|---|
| WASD (or a gamepad's left stick; the arrows too with "Zenith 0.2.2's keys" on or Factorio's keys off) | Walk, relative to the camera, at any angle (the bridge steers Factorio's 8-way character to follow it). The stick walks only on a gamepad Godot recognises, once it has been seen centred: pedals, wheels and throttles are left alone |
| Right mouse (hold) | Mine what's under the cursor; a train, wagon, car, tank or spidertron under it first (issue #10: not the rail beneath), with what is inside it; an item lying on the ground (over ore, under belts and buildings) is picked up at once. While it mines the character stands, as in Factorio: walking goes on once mining stops. What is mined follows the cursor as Factorio's selection does (J26): a new target starts again from nothing, the cursor off it keeps its progress, and with the button held a walk goes on over nothing and stops on the next thing under the cursor, so walking along a line of belts with the cursor on it mines every belt in turn. Out of reach it says "Out of reach" and doesn't swing, no sound or sparks, as Factorio (issue #24; `--mine-reach-check=off`: the swing played anyway, as before) |
| Enter (or G; Keypad Enter instead of G with "Zenith 0.2.2's keys" on or Factorio's keys off) | Get into the nearest vehicle (car, tank, train, spidertron) or out of it |
| Spidertron remote (shortcut bar) | Drag: select spidertrons · Shift+drag: add · right-drag: remove · click: send them there · Shift+click: queue a waypoint |
| WASD in a vehicle | W accelerate, S reverse, A/D steer (relative to the vehicle). As in Factorio, S while going forward brakes and then reverses; Settings > Interface > "Vehicle: opposite key brakes and holds" (or `--vehicle-brake-hold=on`, `=off` to force Factorio's way for one run) makes the opposite key brake a car, tank or locomotive to a stop and hold it there until let go (the client sends `h` 1 with `drive`; the mod stops it at its own speed, no creeping). Off by default; spidertrons unaffected |
| F (hold) | Pick up items next to the character, lying on the ground or on belts (as Factorio's "Pick up items": everything within the character's item pickup distance, the nearest first), each flying to the character with its sound; not with Ctrl or Alt held, Ctrl+F and Alt+F being search and the personal roboport, as in Factorio |
| Space (hold) | Shoot at enemies near the character (the game picks the target) |
| Shift+Space (hold) | Shoot at the cursor (C with "Zenith 0.2.2's keys") |
| C | Switch to the next gun (or click a gun in the weapon slots left of the quickbar; Tab with "Zenith 0.2.2's keys") |
| E | Open the character window (the inventory on the left; on the right Factorio's Crafting and Logistics tabs, Logistics once the character's logistics are researched), whatever is under the mouse. With any window open, E closes it. The main inventory sorts itself as Factorio's does: whenever it changes while no window shows it, and when the window closes (not while the hand holds one of its stacks) |
| Esc | Close the open window, machine screen, map view, chooser or remote view; with none open, the Game menu (Resume, Load game, Save game, Save as, Settings, Exit; Players when others play too). With the mouse resting on something whose tooltip shows (a button, an item's slot), Esc still does this at once: Godot spends an Esc on hiding its tooltip, so Zenith sends the key again (`--esc-tooltip=old`: the first Esc only hides the tooltip, as before) |
| T | The technology screen: the research in progress and queue, the selected technology (cost, time, prerequisites) with Start research / Add to queue / Cancel, and the tree on the right. It opens on the research in progress; with none, on the technology looked at last while it is still to be researched, else the first available one, the list of technologies at its top (L9; `--research-open=last` opens on the one looked at last even when researched, as before); the tree scrolled to it. A Factoriopedia link opens it on its technology. Start research / Add to queue on a technology whose prerequisites aren't researched queues the missing ones first, in order, then it, as Factorio's screen does (L12, its tooltip names them); it is greyed when one of them is unlocked by doing its task (Factorio queues no trigger technology) or the queue's seven can't hold them all (`--research-chain=off` greys it whenever a prerequisite isn't researched, as before). Such a technology, one Start research can queue, is orange in the list, the tree, the details and the queue (Factorio's conditionally available slot; red stays for one a trigger technology is on the way to, and with `--research-chain=off` nothing is orange); `--research-orange=factorio` draws only Factorio's own orange ones, whose prerequisites are all researched or queued. A recipe among the Effects has Factorio's recipe tooltip (its ingredients, crafting time, products and Total raw, then the item's lines; nothing red), as do the Unlocks recipes on a technology's Factoriopedia page (M3; `--research-effect-tips=old`: the name and "Unlocked by this technology", as before). The screen covers the HUD, Zenith's Show in Factorio button with it, as Factorio's covers its mod buttons (M4: the gear sat on "Research queue"; every window now draws over the button, `--mod-button=over` keeps it on top as before). T, E, Esc or × closes it. A lab's window follows the research too: its box names the research in progress with its share, and after one finished with none started since says Factorio's "<name> finished. Press T." with that technology's icon and a full bar (`--lab-finished=old`: "No research in progress. Press T." as before) |
| Tab or M (M only with "Zenith 0.2.2's keys") | The map view: the charted map over the whole window (north up) with your character's arrow, the map tags and trains. Drag (left or middle mouse) or the movement keys (WASD, the arrows with "Zenith 0.2.2's keys" on or Factorio's keys off, or as rebound) move it (Shift: faster), the wheel zooms about the mouse. Right click: on a tag, edit or delete it; on a ghost, remove it; elsewhere, create a tag there (icon, name, Confirm). Double click also creates or edits a tag. Tab, M or Esc closes it (Esc closes the tag dialog first). The game keeps running underneath, and the character doesn't walk while it is open |
| Minimap (top right) | The charted map around the character (in the map view or remote view, around what that looks at), north up, with tags and trains. Click it to open the map; the wheel or its + / − buttons zoom it |
| Click a stack (inventory or machine) | Pick it up into the cursor, as in Factorio (right click: half). The cursor shows its icon and count; its slot shows Factorio's hand. Over the world, where the held building's ghost shows, the count alone is drawn by the pointer, as Factorio does (L7; `--cursor-count=old`: none there), counting down at once as you build (the builds sent and not yet gone from the inventory shown are taken off). The quickbar's count and the inventory's slots count those builds out at once too, and get them back if the game refuses one (L2; `--slot-counts=report`: they wait for the bridge's inventory report, up to half a second, as before) |
| With a stack in the cursor, click a slot | Put it there (a different item swaps, so the other stack is now in the cursor); right click drops one; click its own slot, or Q, to put it back. Left mouse in the world builds it (only stacks from the inventory) |
| Shift+click a stack | Move it between the inventory and the open machine (Ctrl+click: all of that item) |
| Click a recipe | Hand-craft one (right click: five, Shift: as many as possible). Hover for ingredients (red, as have/need, only where neither held nor hand-craftable from what is held), time, products and Total raw (red where fewer are held). An assembler's recipe chooser has the same tooltip, nothing red |
| Crafting queue (bottom left) | Each queued craft with its count; the first fills with Factorio's orange pie. Click cancels one, right click five, Shift+click the whole entry. Longer than its row, it ends in "+N": hover it for the rest (opening upwards), click it to keep them open and cancel crafts there |
| 1 – 0 | Hold the item pinned to that quickbar slot (again: put it away): one stack of it from the inventory, the biggest, its slot marked with Factorio's hand and the cursor counting that stack, as Factorio's cursor holds one stack; building, Z, tiles and capsules use that stack up (the client names its slot, `hs`), then the next stack of the item comes into the hand (of the same quality first), Q puts it back, a click on a slot puts it down (L7; `--hand-stack=all`: the item with no stack in particular and all of it counted at the cursor, as before). With none in the inventory, a ghost cursor of what it builds. With the character window open: pin the hovered item, or the held one, to that slot |
| Click a quickbar slot | Hold its item; with an item held, pin that item there. Right click clears the slot. Inventory items can also be dragged onto it |
| Left mouse (hold and drag) | Build the held item along the way, as Factorio drags: belts go along the held belt's line, each facing the held way, forward with it and backwards against it (J25: a line can be built from its end), nothing off the line or going back over it; R while dragging turns the line at its last belt towards the cursor and builds out to it (with Smart belt building, Settings → Interface, an obstacle or a crossing belt is jumped with undergrounds, the entrance upstream either way; with Lock belt building to straight line off, belts follow the cursor round corners instead); pipes go in a line (pipes-to-ground over obstacles), walls follow the cursor's path round corners and in any shape, a diagonal filled as a joined staircase (N5; the line lock is the belts' alone, as in Factorio; `--wall-drag=line`: along one line, as before), poles at their wire reach, anything else one footprint after another; a faster belt dragged over a line replaces it. Its ghost is green where it can go (a splitter or underground over belts, a pipe-to-ground over pipes replaces them), red where it can't (none left, beyond the 10-tile build reach, something in the way). None left counts the builds just sent that haven't left the inventory shown yet (the bridge reports the inventory up to half a second after a build), so a drag stops, and shows nothing, past what the hand holds, as Factorio places nothing then (L2; `--build-spend=off`: the inventory shown alone, as before, when a fast drag went on past it and the game took the extra buildings away again). What a build spends is judged by the bridge's own reach (the build distance plus 1.5 tiles, to the building's middle): a small building up to a tile past the cursor's reach has a red ghost and is still built, and counts (`--build-spend-reach=cursor`: by the cursor's reach, as before, when a drag begun there sent one or two too many). Holding an electric pole tints the supply areas of the poles round the cursor and its own in Factorio's blue; hovering a pole shows its own. Holding an underground belt or pipe-to-ground shows Factorio's underground connection to the piece it would join (yellow on the tiles between) and, green, the furthest its exit may go; past that the connection turns red, too far to connect; with nothing to join, the furthest tile its exit could go (J24). Over a plain run of belts (pipes) the tiles between show Factorio's underground_remove_belts instead, red-orange corner brackets and the yellow arrow (pipes without it): building it mines them (the bridge's `under_clear`), and Zenith hides them as the build is sent, back if the game keeps them (M2; `--underground-clear=off`: neither, as before; `--underground-clear-sent=off`: a drag's pair hides its run only when the game answers). Over a window the mouse only works the window: nothing behind it is hovered, built or mined. Where a click lands (J9): the cursor's point is sent rounded down to 1/256 tile, so the bridge snaps it to the grid exactly where the preview stood (Factorio's rule: an odd size on the tile's middle, an even one, a splitter across, on the nearest tile edge; real 2.1.24's own create_entity snaps the same in every direction). Cut towards zero, as before (`--build-wire=truncate`), a point less than 1/256 tile under a tile's edge or middle at negative coordinates was built one tile over; the tile brush's point too |
| Holding a blueprint, left click | Place its ghosts there (shown under the mouse first; robots build them; building the item over its ghost fills it in yourself). Ctrl+Shift+click: super-forced (trees and rocks in the way are marked). A book places its active page; Shift+mouse wheel picks the page |
| Holding a deconstruction or upgrade planner, left drag | Mark the area (Shift: cancel the marks). What it will take is highlighted in its colour while dragging |
| B | Blueprint library: My blueprints (kept by the client in `user://blueprint-library.json`), the save's Game blueprints and, when the bridge plays the save's own player, that player's library. Click takes one into the cursor, right click opens it (books open in place), drag moves it or drops it into a book, Del deletes; Import string takes a string copied from Factorio or a website; New book / planner buttons |
| Right click a blueprint, book or planner in the inventory | Its window: label, icons, description; a blueprint's components (click one to take it out), what it includes, snap to grid and absolute snapping; a book's pages; a deconstruction planner's filters, whitelist / blacklist, trees and rocks only, tile mode; an upgrade planner's from → to rows. Save writes it back; Export string copies Factorio's string |
| Ctrl+mouse wheel | The held item's quality (the qualities your force has) |
| Ctrl+Shift+left | Super-forced build: a ghost, and what stands in the way is marked for deconstruction |
| Holding tiles (stone brick, concrete, landfill, foundation...) | The brush shows at the cursor (green, red where the tile can't go, blue as ghosts with Shift). Left mouse paints, right mouse mines placed tiles back; Numpad + / - change the tile area; R turns hazard concrete |
| Holding rails | Click a rail end, or anywhere along a line to fork a new one off it, to start the rail planner there: the path of straight and curved rails to the cursor shows, click (or drag from the end) builds it and carries on from its end; ghosts where your rails run out. Alt+R (while holding rails; otherwise it gives red wire): rail layer (a ramp up, elevated rails with supports). Right click lets go |
| Holding grenades, cliff explosives, capsules | The throw range and blast show; left click throws at the cursor (hold to keep throwing). Fish heal you |
| R / Shift+R | Rotate the held item (rails by 45°), or the hovered entity: an underground belt turns with its other end, both swapping entrance and exit, as Factorio turns a pair (J23). While dragging belts it bends the line (see Left mouse). Building the same belt over a belt turns it; a faster belt (or anything that fast-replaces) replaces it |
| Left mouse with nothing held | Open the hovered building's screen (chests, assemblers, furnaces, labs, drills, boilers...) beside your inventory: its name, status (Working, No ingredients, No fuel, No power...), energy, slots and fluid boxes. E, Esc or its × closes it. With `--click-open-held` (on; `--click-open-held=off` builds on click as before), plain left-click while holding a placeable entity over a real openable building/mover also opens it unless upgrading/fast-replacing, rotating the same entity type in a new direction, reviving a matching ghost, or holding Shift/Ctrl |
| Recipe slot in an assembler's screen | Click to pick its recipe from the grid below; right click clears it. Items it was holding come back to you |
| Q | Put the held item (the cursor stack) away; with nothing held over an entity, a train, wagon or vehicle, the pipette: hold its item, turned the same way (a ghost cursor when you have none) |
| Z (hold) | Drop one of the held item: into the machine or chest under the mouse, onto a belt, or on the ground |
| Shift+left click | Holding an item: build a ghost of it for robots. Holding nothing: paste the settings copied with Shift+right click (recipe, filters, requests, combinator settings) |
| Ctrl+left / Ctrl+right click an entity | Fast transfer: the held stack (half) into it, or with nothing held its output (half) into your inventory. When the held stack empties, the next stack of the item comes into the hand |
| H / V | Flip the item being built, or the entity under the mouse (machines with fluid boxes) |
| Alt | Alt-mode: recipe and filter icons over every machine in view (they come with the buildings, issue #9; an idle furnace keeps its last recipe's, J2), over each chest the kinds it holds most of, up to four (the bridge reads the chests round the focus about once a second while Alt-mode is on, J6), over machines the modules in them, over labs their science packs, over ammo turrets their ammo and over locomotives their fuel, in rows where Factorio puts them (its prototypes' icons_positioning; a beacon's only with the mouse on it; read in the same rounds, K1, K2; `--alt-ammo-fuel=off`: no ammo or fuel, as before), each machine's own icon shifted and scaled by its icon_draw_specification (`--alt-icon-spec=off`: centred at one size, as before), where icons overlap the one nearest the camera drawn in front (a north-south line of assemblers' recipes in the angled view, a lab's lower row of packs over its upper, a turret's ammo over the lab behind it; in the angled view, F6 and first person; `--alt-icon-order=old`: in the order found, a farther icon over a nearer one as before; the order kept steady while the camera only moves, so icons at one depth (a row of chests or inserters) no longer swap places and flicker while panning or running; `--alt-depth-order=old`: ordered by depth from the camera as before (the CPU path's: the icons drawn by the graphics card are always in the steady order); the icons are placed and drawn by the graphics card in the angled view and F6, sent to it only when they change, so a moving camera costs the CPU next to nothing (their pictures copied into one texture array, at most 16 new ones a frame, the rest blank for a frame or a few; never more layers than the card allows); first person, the remote view's fog and a headless run stay on the CPU; `--alt-icons=cpu`: every icon worked out and drawn on the CPU each frame as before, `--alt-icons=gpu`: the card even headless; chests' contents, machines' rows and pipes' fluids kept per chunk and built again only for a chunk that changed (a chunk built again or unloaded, one chest's or machine's row, a pipe whose fluid changed), in view the frame it changes (at most 3 ms of chunks a frame, the rest a frame later), so walking no longer rebuilds the whole map's icons several times a second; `--alt-incremental=off`: the whole map's built again as before; the card's icon instances sorted, packed and joined in C++, AltIconsNative, a turned view sorting every chunk at once with no GDScript per chunk; `--alt-native=off`: in GDScript as before), Factorio's fluid arrows on machines and pumps and a recycler's output arrow, inserters' arrows when chosen in Settings → Interface (kept between games; `--alt-cache=off`, `--alt-flat-batch-tex=off`, `--alt-arrows-opt=off`, and `--quality-marks-opt=off` restore uncached/unbatched Alt-mode and mark passes); it toggles when Alt is let go, unless Alt was held for an Alt+click |
| Alt+click | Factoriopedia's page of the thing under the mouse (in the world, or a slot or technology in a window) |
| F2 | Factoriopedia |
| L | Logistic networks: every network of the force, its robots and items |
| Ctrl+C / Ctrl+X, drag | Copy or cut an area to the clipboard; then left click pastes it (R turns it), right click puts the tool away. Ctrl+V pastes the clipboard again |
| Ctrl+Z / Ctrl+Y | Undo / redo your own building (marks it for deconstruction) and mining (puts a ghost back), blueprints placed, planner marks, pasted settings and rotations |
| Alt+B / Alt+D / Alt+U, drag | A new blueprint of the area in your inventory (its window opens) / mark the area for deconstruction (Shift: cancel) / the upgrade planner (a new one if you have none) |
| Alt+R / Alt+G / Alt+C (or the shortcut bar) | Red, green or copper wire: click an entity, then another to connect them (the same pair again disconnects them); the wire then hangs from the second, so a row is wired click by click. The hanging wire is drawn to the mouse with a ring for its reach (grey past it). Click a combinator's front (output) or back (input) half, a power switch's left or right side. Right click lets go of the wire, again puts the tool away |
| Shift+click a pole | Remove its copper cables |
| Open anything on a circuit network | Its circuit connection (enable/disable condition, read modes, set recipe / filters / stack size...) and logistic connection settings; combinators in full (decider conditions with and/or and red/green inputs, outputs; every selector mode; constant combinator sections); lamp and train stop colour, speaker, pump filter, turret priority targets, display panel messages |
| P / K | Production statistics (items, fluids, pollution, building counts; this surface or all; Factorio's graphs: click a row's box to draw it) / kill statistics, over Factorio's 8 time scales |
| ` (or / with "Zenith 0.2.2's keys" on or Factorio's keys off) | Chat (a line starting with / is a console command, run over RCON when this client started the server) |
| Ctrl+F | Search the crafting recipes |
| Shift+1 – 0, X | Show quickbar page 1–10, swap the two quickbar rows |
| Middle click an inventory slot | Filter it to its item (or the held one); again clears it |
| Click a car or wagon | Open it: fuel, trunk, ammo, cargo; a train's window has Factorio's schedule (every wait condition, and/or), interrupts, Go to station now (a temporary stop), the whole train's cargo and fuel, and a camera above it. A train stop's: name, limit, priority, circuit settings |
| Map: zoom in past the closest zoom | Remote view there (in Factorio's angle, F6's view), on any surface the map shows: WASD moves it, Esc or M goes back to the character, and zooming back out goes to the map there. Ground no working radar, roboport (its construction area) or the character sees lies under a dark fog, with nothing moving there |
| Ctrl+F9 | Show in Factorio: bring Factorio's window to the front on the same game (or start it joined to the server the client started) |
| , / . | Turn the camera 90° |
| Middle-mouse drag | Turn the camera freely (left/right) and tilt it (up/down) |
| Page Up / Page Down | Tilt the camera |
| Mouse wheel | Zoom |
| F6 | Jump to Factorio's own view (north up, from above at Factorio's angle and default zoom); again to go back. Zooming, turning or tilting out of it gives the normal view its own projection back (Settings > Camera), and F6 snaps to Factorio's view again (L1; `--f6-leave=old`: it stayed orthographic) |
| F5 | First person: see through the character's eyes, mouse looks, aim with the crosshair; F5 again to go back. The mouse is freed while a window is open. The crosshair acts on what it is on (K7): the nearest entity its line of sight meets (each Factorio selection box raised to its model's height, standing on the hills), within 64 tiles, before the ground; only with nothing in the way does the ground under it decide. Hovering, mining, opening, rotating, Ctrl+click, Z and the wire tools take that entity; a held building goes just out from the side looked at (on a top, where the crosshair is). The bridge still refuses what is out of reach. `--fp-pick=ground` picks from the ground point as before |
| F7 | Perspective or orthographic for the view in use, switching what is on screen: in first person first person's, in the map's remote view the map's projection, elsewhere the normal view's (in Factorio's view, F6, the view goes perspective where it stands, out of Factorio's view, and F6 snaps back to it; L1); kept in Settings > Camera. `--f6-leave=old`: in Factorio's view it changed only the normal view's setting, used on leaving it |
| F1 | Show or hide the help panel (off by default): every control under the key bound to it now (rebound in Settings → Controls, or Factorio's own keys), grouped (moving and camera, fighting, building, blueprints and wires, inventory, windows, the map, Zenith's own), then each add-on's while it is on; the debug menu only in dev builds. When the window is too short for it, the mouse wheel over it scrolls it |
| F4 (dev builds) | Show or hide the debug line (tick, chunks, entities, packets, the game's UPS, FPS). Public builds give it no key by default (issue #26: many players have F4 on a Factorio control, Factoriopedia's alternative or their own); it stays in Settings → Controls (Miscellaneous, Debug line) to bind, and a key bound there is kept in either build |
| Alt+L / Alt+F / Alt+E | Personal logistic requests, the personal roboport, exoskeletons on or off (also on the shortcut bar) |
| Ctrl+= / Ctrl+- / Ctrl+0 | UI scale up, down, back to automatic |
| Ctrl+F12 | The debug menu (dev builds only, see "The debug menu" below) |
| Add-ons' keys | Each add-on's own, listed under it in Settings → Controls and in F1's help while it is on. The bundled Cinematic camera: F8 free camera, Shift+F8 its window, Ctrl+F8 idle mode, Alt+F8 camera mode, Ctrl+Shift+F8 record, F11 hide the interface, F12 screenshot; while its camera flies, WASD, E/Space and Q/Ctrl, = and -, O orbit, T follow, N next, V placement, K add a path point, P play the path, B letterbox |

Client command-line options go after `--` (Godot: Project → Project Settings → Run, or the
command line): `--factorio-port=34200 --port=34201 --models=/path/to/glb/folder
--factorio-data=/path/to/Factorio/data`.

**Model packs** (client/scripts/world/model_packs.gd): every model comes from a pack, each a set of
models found by file name (`<prototype-name>.glb` or `.gltf`). Three are built in
(`client/assets/models/packs/`: FUE5, Wube3DP and Placeholders, 481 models in all); the
`models` folder beside Zenith (the checkout's root, or beside Zenith.exe) holds any number more: the
files at its top ("Loose models"), each folder in it (models anywhere inside) and each `.zip` in it,
read as it is (a download's `models/Zenith.zip`, Vasillo's models, is one). A zip is unpacked once
into `user://model-packs/<zip name>-<size>-<modified>/` on a worker thread at start-up
(ModelLibrary's `ready()` says no until it is in, the join's loading screen counts it), again only
when the zip changes; a copy of a zip changed since (same name) is removed at the next start. A copy
of a zip this models folder doesn't have (another launcher's or checkout's: they share one user folder)
is kept until it has gone unused 7 days, so switching between launchers doesn't unpack 2 GB again
(about 12 s and 2 GB of writes); each start stamps the copies it uses (`<copy>.used` beside it).
`--pack-cache-keep=<days>` changes the 7; `--pack-cache-keep=0` removes them at once, as before. **Copies of
Factorio's files** (`client/scripts/world/pack_check.gd`, the owner's rule): a pack holding any file
over 1 KB that is a byte-for-byte copy of one in the install's `data/` folder isn't loaded at all, its
card red in the Model packs window ("Show the files" lists them), one warning line in the log. Every
pack is checked but the Factorio pack and Wube3DP; there is no switch to turn it off. A pack's file is
compared first with the install's file at the same Factorio path (`sounds/<mod>/...`, `icons/...`, `tiles/...`, `decoratives/...`, a
`<mod>/` or `__mod__/` folder in its path), then with the install's files of the same size, by SHA-256.
The install's sizes are listed once, on the model packs' worker, into `user://pack-check/install.json`
(again when base's version, `base/info.json`'s modified time or the data folder's changes; it keeps the
hashes it took). Each pack's answer is kept in `user://pack-check/packs.json` by its id, its stamp (a
zip's size and modified time; a folder's file paths and modified times; a built-in pack's file paths and
Zenith's version) and the install's, so an unchanged pack takes its answer at start-up (about 3 ms for
the built-in packs) and a new or changed one waits, not in use and its card saying "Checking for copies
of Factorio's files…", until the worker has checked it (a first run against a full Space Age install:
about 1.3 s on the worker, FUE5 and Placeholders included). Without an install nothing is compared: the
packs load at once, the window's details saying so. Delete `user://pack-check/` to check every pack
again (a built-in pack's model edited in place in a checkout keeps its answer until then). One order decides,
the higher pack winning where two have a model of one name (settings.cfg `[model_packs]` `order` and
`off`, by id: `builtin:<folder>`, `loose`, `dir:<folder>`, `zip:<file>`): a new pack of the models
folder goes on top, on; a built-in one not saved yet goes under the folder's, so by default, from the
top (the owner's order), Default (when there is one), FUE5, Wube3DP, Placeholders. Placeholders is
always last and always on. With that order the seven models FUE5 and Wube3DP both have
(electric-mining-drill, iron-chest, small-electric-pole, steel-chest, steel-furnace, stone-furnace,
wooden-chest) are FUE5's, as all 39 were before the packs; Wube3DP's stay in their pack.
`choices` (family -> pack id) takes a model family (a prototype's model with its direction, curve, piece, shape, richness and pose variants; ModelPacks.family)
from that pack whatever the order: each variant it has, a tier it has only the base of as the base
recoloured, the variants it lacks from the order. The Model packs window
(client/scripts/menu/model_packs_window.gd: the main menu and the Esc menu; not in Settings) sets all three and applies them at
once (ModelLibrary `apply_packs`, `apply_choices`; world.gd `models_changed` builds the chunks drawing
those models again); trains, robots, creatures and inserter arms keep theirs until a restart. A
building window's Model button (model_chooser.gd) draws that one building from a pack of its own,
kept per save and unit number in `user://building_models.cfg` (building_models.gd, forgotten on the
building's `del`), or sets its family's choice; client only, no protocol change. The hover panel (entity
info) shows the pack drawing the building as a small picture at the right of its title bar (N8: the
pack's own picture as its row in the window has it; nothing for an entity no pack nor Factorio's card
draws), its tooltip "Model: <pack>" and its credit; a click opens the Model packs window on that pack
with the building's family shown. The panel holds its building while the mouse is on it, or for up to
0.6 s while the mouse heads straight for it from the building, so the picture can be reached.
`--entity-info-pack=off`: no picture, the panel follows the mouse as before. A zip that isn't one,
or one whose entries can't be read (a damaged file, or another compression than deflate), is left out
with a warning in the log. The start-up log says
`[models] N model(s) from M packs, the higher winning: <pack> (<where>, <count>), ...`, then the packs
off or being unpacked and the models a higher pack covers; the dev build's debug menu (Tests > Model
packs) lists each model's pack. `--models=<dir>` adds one more pack (a folder, searched the same way)
on top for that run, which only fills in entities no other pack has a model for; `--models-first`
lets it win over every pack. `--no-custom-models` leaves the models folder's packs out; the built-in
ones stay (`--models=` still applies).
A modeller's textured belts, curves, splitters and undergrounds show their return run: the belt
coming back under the rollers, its texture running the other way at the belt's speed, seen through
the frame between the rollers and where it rolls over a line's end pieces (client/scripts/world/belt_return.gd:
the inner side of the return the model carries, or its top run mirrored under it). Only at full
detail; not in the shadows, the levels of detail or far chunks. `--belt-return=off` draws none, as before.
The space under the top run (the return strip, the rollers) is shaded as a covered space: darker ambient, direct light and fill (the shader's belt_cover, belt_return.gd `cover`; the rails and the top run are not). `--belt-cover=off` is the look before.
The same belts' side plates are closed at their ends: Vasillo's build each plate as a box open at both
ends, and where a line ends or starts, or at a splitter's or underground's open side, the ground showed
through the hole (L3). Each small upright hole in a belt-family model (a closed loop of edges only one
triangle uses, at most 0.25 tiles, flat) gets a cap facing out, wearing the plate's material and UVs,
added to the model's arrays once as it is read (client/scripts/world/belt_caps.gd), so the levels of
detail and shadows have it too. Zenith's own, Wube's and FUE5's belts are closed: nothing is added to
them. `--belt-caps=off` leaves the holes, as before.
`--addons=<folder>[,<folder>...]` loads add-ons from those folders (an add-on's own folder or a
folder of add-ons), always on, ahead of installed ones with the same id ([ADDONS.md](ADDONS.md)); while one is
given, Ctrl+Shift+F5 (Settings → Controls, "Reload the add-ons given with --addons") reloads them from disk, as does
the Reload button on an add-on's page. `--addons-dev` puts Reload on every switched-on add-on's page.
`--addon-reload=off` brings back the old behaviour: no Reload or key, and switching an add-on off and on keeps
the code first loaded (a restart reads changes). Script errors in an add-on's files are listed on its page in
the Add-ons window (and a refused entry script says its line); `--addon-errors=off` leaves them in the log only.
An add-on's `dependencies` (other add-ons, and Factorio mods per game; [ADDONS.md](ADDONS.md#dependencies-17)) are
checked when it starts and set the order add-ons start in; `--addon-requires=off` loads them without checking, in the
order found, as before. `--camera=factorio`, `--camera=first-person` or
`--camera=<yaw>,<pitch>,<distance>[,ortho]` start in that view instead of the Camera setting's
(`--camera=0,48,14,ortho` is close to Factorio's own; a distance past Furthest zoom is kept for that run). The character's body
is the middle of the screen in every view (the angled view at any zoom and tilt, orthographic, Factorio's view), where it is
drawn: on an add-on's hills, flying in mech armour. Across the ground the camera stays on it; up and down it glides a little
(about 0.1 s at the default zoom, quicker zoomed in) so the hills' small kinks don't jolt it; a jump (another target, the
remote view left) glides over. Where a hill would come between the camera and the character it tilts up over it and eases
back after (an orthographic view stands back along its axis instead, so Factorio's view keeps its 48 degrees; issue #17).
`--camera-focus=off` puts the camera as it was before, to compare: at the feet, level over the hills, trailing a little. `--fp-pick=ground` makes first person pick what is under the point its crosshair's ray meets the ground, as before K7, instead of the entity the ray meets first. `--shot-note=old` leaves a screenshot's "Screenshot saved" note unshown when the shot was taken with the interface hidden (F11), as before L15; by default it waits and shows, with Open folder, when the interface comes back. `--screenshot=<file.png>[@seconds]` saves
the window once (default after 10 s; needs a window, which keeps the project's size and mode;
`--scale-like-full-screen` does full screen's Resolution sums with that window as the monitor). `--full-shot=<file.png or folder>[@seconds][,<width>x<height>]`
takes one the way the Cinematic camera's F12 does (`api.view.screenshot`: the moment held, full detail, the view's chunks, the game held for the picture), default after 10 s. `--open=<unit>` opens that entity's machine screen once
it has loaded (for screenshots and debugging). Also for screenshots: `--ui=inventory` opens the
character window at start, `--ui-sample` feeds sample recipe details (crafting tabs, ingredients)
through the hooks the mod's full UI data will use and pins a few quickbar items,
`--ui=research` opens the technology screen, `--ui-hold=<item>` picks up that item's first stack after 4 s,
`--ui-craft=<recipe>:<n>` hand-crafts after 3 s (to see the queue), `--ui-hover=<x>,<y>` keeps the mouse
there from 5 s on (tooltips, the cursor stack, the build ghost), `--ui-hover-unit=<unit>` keeps it over that entity
wherever it is drawn (its entity info), `--ui-press=<node name>` clicks that
button or slot after 7 s (popups: `SecondOperand`, `Signals`, `ChangeGroup`), `--map` opens the map view at start
(`--map-zoom=<GUI pixels per tile>`, 0.25 to 8; `--map-tag=<x>,<y>,<icon item>,<text>` adds a tag
after 3 s; `--map-edit=<x>,<y>` opens the tag dialog at that window point after 5 s), and `--ui-scale=1.25`
overrides the UI scale (by default 100% up to a 1080-line window, then in steps of 25%, like
Factorio's automatic scale: 150% at 2880x1659). `--alt-mode`, `--stats=<item|fluid|kill>`,
`--chat=<text>` and `--remote=<x>,<y>` turn on Alt-mode, open statistics (also `pollution`,
`build`), say a line, or look somewhere in remote view after 3 s. `--ui=networks` opens the logistic
networks window, `--pedia=<kind>:<name>` Factoriopedia on a page after 4 s (`item:assembling-machine-2`,
`technology:mining-productivity-3`), `--research=<technology>` selects one in the technology screen.

The inventory, crafting, quickbar, weapon slots, crafting queue, technology screen and machine
screens are drawn with Factorio's own GUI graphics, fonts and names (technology icons, status
dots, the hand, empty-slot pictures, locale files), read from your install like the item icons (`core/graphics/gui-new.png`, laid out as
`core/prototypes/style.lua` does, and `core/fonts`); nothing of the game's is copied into this
repo. Without an install they fall back to flat panels in Factorio's colours. The quickbar is kept
by the client (in Godot's `user://quickbar.cfg`) until the mod sends one.

Networks and ghosts are drawn like Factorio's: copper wires sag between the poles' insulators (red
and green circuit wires beside them), a machine with no power blinks Factorio's red lightning icon
(one tile wide; low power has no icon, as in Factorio: it only slows machines), lamps without power
stay dark, storage tanks show their level in the fluid's colour through a window on their south
side, and hovering an entity with fluid or a power problem lists it by the cursor. A machine no pole
reaches shows Factorio's unplugged icon within about a second round the camera (the bridge's
once-a-second power read there, and the tick after a pole or an electric machine is built or
removed; J5); further away it comes with the alerts' slower pass. The entity info
panel on the right (Settings → Interface → Entity tooltip on the side) shows the hovered entity as
Factorio does: its status (No power, Low power...), recipe, a crafting machine's ingredients and
products a second at its speed with its modules, beacons and productivity (J15), modules, the
beacons reaching it and their effects (a beacon: its modules and the machines it reaches), and for a powered building
Factorio's "Consumes electricity" (Max. and Min. consumption and the Electricity bar from its
buffer). Hovering a roboport draws orange lines to the roboports it is linked to; holding one
draws the links round where it would go. Ghosts are the entity in translucent blue-white; entities
marked for deconstruction get the red cross, for upgrade the green arrow. The icons come from your
install's `core/graphics` (plain coloured discs without one).

Items on belts and on the ground are drawn as cards with the item's icon, read from your Factorio install (the
client looks beside the factorio.exe set in Settings → Factorio first, then the usual Steam and
standalone locations; `--factorio-data` points it at the `data` folder otherwise). The install is
found once at start-up: after changing that setting, restart Zenith (Settings and the main menu say so). Without icons, items are small coloured blocks. The headless build
has no graphics, so it can't supply icons.

### Modded games

A modded game shows each mod's own icons, ground, decoratives, names and, for buildings Zenith
has no model of, the mod's own picture on a card facing Factorio's camera (docs/MOD-GRAPHICS-PLAN.md).
The bridge lists every prototype's graphics at the data stage and sends the list once per set of
mods (`gfx`, docs/PROTOCOL.md); the client keeps it in `user://mod-graphics/` and reads the pictures
from the mods themselves, never copying them: the server's mods folder (`server/data/mods`, which
the menu's servers use), then your own (`%APPDATA%\Factorio\mods`, `~/.factorio/mods`), then a
portable install's, or `--factorio-mods=<folder>[;<folder>...]` first. Mods may be folders or zips;
the version the game runs is picked when a folder holds several. Load game on a modded save links
your own mods folder's mods into the server's and runs Factorio's `--sync-mods` on the save, so the
server runs the save's mods at its versions, adds the mods turned on in the Mods window (unless Sync
mods with save is ticked; "Modded saves from the menu" above), then turns the bridge on; a mod missing
there (or there at another version) is named with its version, since Factorio, with no mod portal login
on the server, says only "unknown error". Their machines' pictures move while
they work (16 frames of each loop, when Settings > Graphics > Animate modded buildings is on; off by default). What
isn't drawn yet: those cards' working lights at night, and a mod that changes graphics in its own `data-final-fixes`
after the bridge's (its list is made before) shows the earlier pictures.

The ground uses Factorio's own tile pictures from the same install: `base/prototypes/tile/tiles.lua`
(and Space Age's) say which picture, variant sizes, weights and layer each tile has, and the
pictures come from `*/graphics/terrain/`. Each tile shows one of Factorio's 1x1, 2x2 or 4x4
variants, picked per position the way the game does, so fields don't look tiled; higher tiles
(by Factorio's layer order: grass over dirt over sand, floors over ground) spread over their
lower neighbours with a ragged edge like Factorio's transitions; concrete and other floors keep
crisp edges. Water uses Factorio's water pictures with deep and shallow water blending, and the
coast wanders off the tile grid with a wet rim instead of square banks. Pictures are loaded the
first time a tile type appears (the console prints `Terrain: <tile> ...`). Without an install,
or with `--plain-terrain`, the ground is the map colours with procedural detail.

### The map and the minimap

The map and minimap show what your force has charted, drawn by the mod like Factorio's map (tile
colours, then ore, trees and rocks, then buildings in their map colours; see "Map" in
docs/PROTOCOL.md). The mod sends at most 2 tiles per pixel and 4 chunks a tick, so the client asks
only for what is on screen, a 32 x 32 chunk block at a time from the middle out, asks again every
4 s (minimap) or 6 s (map view) for the same area, and skips ground it knows is uncharted except
at the edge of charted ground and in a full pass once a minute. The mod keeps a chunk's picture
for 30 s while as many entities stand in it and nothing was built, mined, rotated or destroyed there,
and (the perfbridge2 round) trusts the count itself for 20 s after it was made unless such an event
came, so a refresh of a kept chunk reads nothing but its pollution and signals; its robot dots come
from the movers' last search of the live-update area where that covers the chunk (a chunk outside it
is searched as before). A change no event tells of (a tree dying) shows within 20 s. Every 30 s, when it is idle, the
minimap also asks for the area the map view opens on, so the map opens filled in. Uncharted ground
is black, and charted ground no working radar (or the character) sees is dimmed, as on Factorio's
map. In Zenith roboports reveal too (Factorio's don't): ground whose chunk has its middle in a
roboport's construction area counts as seen, on the map, the minimap and in the 3D remote view.
The bridge's character has no player, so the mod charts around it itself while a client is
connected. While the map view is open the minimap shows what the map looks at, and in the 3D
remote view what that looks at, as in Factorio.

Over the chart, the map view draws what Factorio's map view settings switch (Factorio's grid of
icon buttons under the side menu, lit orange when on; also in Settings → Interface): tags, electric
networks (poles' supply areas and their copper wires), logistic networks (roboports' logistic and
construction areas), turret coverage, train stop names, worker robots, rail signal states, recipe
icons and pollution. Trains are drawn live in their own colours where radars see them. The mod sends them with each chunk's chart (`ov`, see
docs/PROTOCOL.md "Map"); the minimap, as Factorio's, draws none of them (only trains, train stops'
markers and tags). The logistic layer shows every roboport
on the surface, not only those on the charts loaded: the client asks the mod for the whole list
(`mrp`) every 10 s while a map or the remote view needs it. Overlapping areas read as one region,
as on Factorio's map.

**Other surfaces.** The map view's top-left panel lists the planets that have a surface and your
space platforms (Factorio's surface switcher); clicking one shows that surface's map and tags (tags
added there go on that surface). A planet's map centres on your cargo landing pad there (its middle
when there is none), a platform's on its hub. Closing the map goes back to the character's surface. Zooming in past the closest zoom on another surface opens the remote view
there: the mod streams that surface's world until the remote view ends.

**Building from the map.** Zooming in past the closest zoom goes to remote view (the camera moves,
the character stays). There, as in Factorio 2.0, whatever you place is a ghost for the robots,
blueprints and the copy / paste tools place ghosts, the deconstruction and upgrade planners mark
areas, and right-click (mining) marks the entity under the mouse for deconstruction. All of it only
on ground the force has charted ("You can't build in an uncharted area"), and on another surface
too. On a platform only what the platform can build is placed: nothing over empty space, nothing
its gravity forbids (both red in the preview). Mining by hand, picking up, shooting, dropping, fast
transfers, wires and throwing wait until you are back with the character. Buildings where radars
or roboports see open from the remote view for their settings; their items stay out of reach. Holding a module and
clicking a building or ghost asks for it (an item request, brought by robots or a platform's hub;
within reach it goes straight in), and so does clicking a module slot of a screen opened from the
remote view; right click on that slot takes the request back.

**Trains.** The side menu's Trains button, or "All trains" in a train's or stop's window, opens
Factorio's trains overview: Trains, Stations and Groups tabs, and a card for every train of the
force with a live view of it from above, its state, carriages and cargo; clicking a card looks at
the train in remote view.

The map's options are in the `[map]` section of `user://settings.cfg`;
`client/scripts/ui/ui_settings.gd` gives them limits and a `changed` signal
(`UiSettings.shared().set_value("map/minimap", false)`):

```
[map]
minimap=true        ; show the minimap
minimap_size=240    ; its side in Factorio GUI pixels (times the UI scale), 120 to 480
minimap_zoom=1.0    ; GUI pixels per tile, 0.25 to 4 (Shift + wheel over the minimap changes it)
minimap_tags=true   ; tags on the minimap
show_tags=true      ; the map view's switches (the map view only): show_tags, show_electric,
show_turrets=false  ; show_logistic, show_turrets, show_stops, show_robots, show_signals,
                    ; show_recipes, show_pollution (off by default)
```

### Sound and effects

The client plays Factorio's own sounds and draws its smoke, explosions and flashes, read from your
install at runtime like the icons (`data/base/sound`, `data/core/sound`, and sprite sheets in
`data/base/graphics/entity`); nothing of the game's is copied into this repo. Working machines
near the camera hum with their prototype's `working_sound` (assemblers, furnaces, drills, boilers,
steam engines, labs, pumps, radars...; at most 12 at once, nearest and loudest first, at most 3
of the same sound), and cars and trains have engine sounds while they move. The character has
footsteps by ground (grass, sand, dirt, concrete, belts, rails, ore), mining hits (each thing's own
mining sound from its prototype: rocks' and the stone patch's stone, Space Age's plants and ice; trees
and plants wood, ore, rocks and fish Factorio's ore sound; a building has no mining sound of its own or
mining particles in Factorio, so its swing is silent and sparkless until it comes off with its mined sound,
M1; `--building-swing=ore` gives buildings the ore sound and sparks, as before; nothing swings at
something out of reach, issue #24: ore past the character's resource reach, anything else past its
reach, each plus the bridge's 1.5 tiles to the target's middle, from `cinfo`, else Factorio's 2.7 and
10; the bridge's refusal stops a swing: "Out of reach" on the held target until the character moves, "Can't mine that" on that target, "This needs a mining drill" or "a pump or drill" on every entity of that kind until the button is let go;
`--mine-reach-check=off` swings at whatever is clicked, as before), building,
rotating and mined-out sounds, gunshots, and biters call and die. Burner furnaces, boilers and
burner drills smoke while they work, steam engines steam, shots flash at the muzzle and where they
land, and things that die explode and leave a scorch mark and a burnt remnant for a while. Biters
and spitters collapse into their corpse, which lies in a blood puddle for Factorio's 15 minutes;
worms leave theirs too. Without an install the client is silent and the effects are plain soft blobs.
A spitter's or worm's acid lands on what it attacks (the bridge's `en` target), on the car or
character there as drawn now, or the target's point (a wall, a turret); `--acid-aim=old` keeps the old
guess: the client's character within 30 tiles, else a point mirrored through the shooter.
Laser and tesla turrets' beams start at the emitter on the head (the foremost faces of the head's upper half, turned with it as it aims), the game's beams too, and distractors' and destroyers' beams at the robot as drawn; `--laser-origin=old` keeps the old start (the head's foremost faces, and the game's beams over the turret's centre 1.2 tiles up).
`--combat-sound-limit=old` restores previous combat sound limits; on by default (`sfx.gd`, `fx.gd`): avoids doubled death sounds when an explosion plays its own sound, restores per-enemy `dying_sound` (`spitter-death*`, `worm-death*`, `spawner-death`) and idle call cues (`biter-call*`/`spitter-call-*`), raises voice polyphony (`Weapons 12`, `Explosions 10`, `Enemies 10`), and rate-limits un-aggregated sounds per file instead of dropping all repeats within 40 ms.
Bullet tracers (a look of ours, Factorio draws none; on by default): each gun turret, car or tank machine-gun and character pistol, SMG or shotgun shot draws a short additive streak from the muzzle to the hit in the ammo's colour (yellow, redder for piercing, greener for uranium; turrets' ammo isn't reported, so theirs are yellow), up to 4 a shotgun shell, at most one per shooter every 0.03 s and 96 at once, wider the further the camera; Settings → Graphics → *Bullet tracers* or `--bullet-tracers=off` turns them off.

Combat lights (a look of ours, brighter than Factorio at night): every gun shot lights its muzzle (one light per shooter, refreshed by each shot; turrets and vehicle guns their own, brighter and wider), every explosion lights the area by its size (bullet hits stay dark; the nuke very wide), flamethrower streams light their arc and where they land, and the fires they leave light 13-16 tiles round, merged a few tiles apart; the pool of 32 lights goes to those lighting the most of the screen (by the camera, not the character), with budgeted dual-paraboloid shadows (up to 6 active casters at once, `--combat-shadows=off` restores unshadowed combat lights). Settings → Graphics → *Combat light strength* (0 none, 100% default, up to 200%); `--combat-lights=old` keeps the older lights (only explosions with a prototype light, the 16 nearest the character) and ignores the slider.
Flamethrower streams (turret, tank, character) start at the gun's nozzle, turned with its head, and land where Factorio's stream entity is; `--flame-origin=old` places them as acid (which drew them from where they land). Their sound is Factorio's begin, looped middle and end from the nozzle, the 3 loudest guns at once; `--flame-sound=old` keeps the repeated one-shots.
Flamethrowers draw one stream a shooter (the turret, tank or character), the newest of the game's stream entities feeding it, landing at the gun's target (a turret's `shooting_target` or a vehicle gunner's aim from `ts`; else the enemy past the stream entity; else pushed out to the gun's range; the character's at its aim), in a higher arc (Factorio's flight × 1.35, at least 0.12 of the distance high); `--flame-streams=old` draws every live stream entity as its own arc to where the entity is, as low as before.

The sound pool (`sfx.gd`, on by default; `--sound-pool=old` keeps the 24 shared one-shot voices, the old category limits and the 12 loop voices): 96 one-shot voices, each category guaranteed a share (Walking 8, Effects 20, Weapons 28, Explosions 14, Enemies 14, Environment 12) and free to use idle voices beyond it; the player's own steps, gun, mining and own vehicle's engine always play; a full category takes its quietest voice (priority, then loudness as heard, fading as a sound plays out) instead of dropping a nearer sound; Factorio's `aggregation` keeps the nearest when it removes; a file still decoding plays another decoded variation or waits up to 0.3 s; the 40 ms repeat check only drops the same file at the same spot. Machine and vehicle loops: "Machine sounds at once" (default 32). Combat sounds Factorio plays that had none (`combat_sounds.gd`, `--combat-sounds-extra=off`): capsule throws, combat robots' guns and loops, the nuke and its aftershock, bullet hits on creatures and the character, biters' attack roars (the bridge's `atk`), spitters' spits, worms' attack roars, the character's heartbeat when badly hurt and the player-died sound.

Volumes are in the `[sound]` section of `user://settings.cfg` (Settings → Sound):

```
[sound]
master=0.8      ; everything
effects=1.0     ; game effects: the five below and everything else in the world
walking=1.0     ; footsteps          environment=1.0 ; machines and vehicles
weapons=1.0     ; shots              explosions=1.0  ; explosions
enemies=1.0     ; biters
ambient=1.0     ; wind and the planet's background sounds
music=0.0       ; Factorio's soundtrack (the planet's own tracks), off by default
ui=1.0          ; window clicks
walking_on=true ; <name>_on=false mutes that slider
max_voices=32   ; machine and vehicle loops playing at once (4-64; 12 before the sound pool)
output_device="Default"
pack_sounds=true ; sounds from model packs (their sounds/ folders)
[graphics]
effects=true    ; smoke, dust, flashes, explosions
pack_tiles=true ; ground textures from model packs (their tiles/ folders)
pack_decoratives=true ; decoratives and 3D grass from model packs (their decoratives/ folders)
decor_models=true ; 3D .glb/.gltf models for raised decoratives (Placeholders + custom packs)
```

Command-line options (after `--`) override the file for that run: `--volume=0.5` (master),
`--sfx-volume=`, `--music-volume=0.3` (turns the soundtrack on), `--ui-volume=`, `--mute`,
`--max-voices=8`, `--no-fx` (no smoke or explosions), `--rocket-vfx=old` (legacy sprite-card rocket launch VFX, diagonal door slide, and no terrain hole or 3D shaft), `--pack-sounds=off` (no sounds from model
packs, as Settings → Sound's "Sounds from model packs" off, `[sound] pack_sounds`), `--pack-tiles=off`
(no ground textures from model packs, as Settings → Graphics' "Ground textures from model packs" off,
`[graphics] pack_tiles`), `--pack-tile-pbr=off` (ignore companion `-normal`/`-height`/`-roughness`
tile maps while keeping pack albedos), `--pack-decoratives=off` (no decoratives or 3D grass from model
packs, as Settings → Graphics' "Decoratives from model packs" off, `[graphics] pack_decoratives`),
`--decor-models=off` (draw 2D sprites and procedural 3D grass shaders instead of `.glb`/`.gltf` decorative models, `[graphics] decor_models`), `--mod-sounds=off`
(a mod's own sound files, its mining and repair sounds, aren't read from its folder or zip: the
defaults play, as before), `--steps=table` (the character's steps from Zenith's name table, as before 0.2.3,
instead of each tile's, rail's, resource's and plant's own `walking_sound` that the bridge sends in `steps`; no
silent tiles and no rustling plants), `--addon-sounds=off` (add-ons' `api.sound.replace` and `mute` are ignored:
Zenith's own sounds play; an add-on's own `play` still works), `--addon-weather=off` (ignores add-ons' `api.weather` sky, cloud, and surface wetness overrides), `--puddle-splashes=off` (disables vehicle puddle splashes and terrain puddle wakes). For debugging, `--sfx-log` prints every
sound started (and `step/grass replaced by <add-on>` or `muted by` when an add-on decided it) and, every
5 s, how many voices are busy, and `--fx-demo` plays the character
through a short script (walk, mine, build, rotate, shoot, then a staged explosion; `--fx-demo=space`
shoots at enemies instead) so sounds and effects can be checked without input. The UI plays
Factorio's GUI sounds through `Sfx.play_ui("gui-click")` (`client/scripts/fx/sfx.gd`).

Sounds follow Factorio's own rules, read from its prototypes (`client/scripts/fx/sound_bank.gd`):
each sound's volume, variations and pitch range; `audible_distance_modifier` and the attenuation
curve over the audible distance (40 tiles, heard from the middle of the view, quieter zoomed out);
`aggregation` (at most `max_count` of one sound at once, the rest dropped or quieter); working
sounds limited to `max_sounds_per_prototype` per kind of machine, faded in and out over the
prototype's `fade_in_ticks`/`fade_out_ticks`, with idle and activate/deactivate sounds; a limit per
category with `priority`; a limiter on the master output so nothing clips. Each planet plays its
`persistent_ambient_sounds` (ambience and wind crossfaded by zoom, the occasional distant sound)
and its own music (`client/scripts/fx/ambience.gd`). The engine's own constants (audible distance,
default curve, category limits) aren't in the data and are chosen by ear. `--fx-demo=stress` adds
ten volleys of 30 biter deaths, 8 explosions and 12 shots, to measure with `--sfx-log` (which also
prints the most voices at once, peaks per bus and sounds started over the same file).

What weapons fire is drawn from Factorio's own prototypes and sheets
(`client/scripts/fx/weapon_fx.gd`, data in `client/data/weapon_fx.json` from
`tools/weapon_fx_index.py`): each shot's muzzle flash, bullet hit and shell casing at the gun's own
rate; rockets with their smoke trail and light, shotgun pellets, cannon and artillery shells,
grenades and capsules on their arc, flamethrower streams, tesla and laser beams, the railgun's beam;
every explosion prototype's animation, scorch marks, fires with burnt patches, poison and slowdown
clouds, and each entity's dying explosion. A headless server doesn't make the explosions Factorio
marks "only when visible" (muzzle flashes, bullet hits, a rocket's explosion), so the client plays
them itself. `--weapons-demo` fires the character's three guns in turn and throws a grenade and a
poison capsule, printing what it drew; against the mock use
`tools/mock_server.py --guns shotgun,rocket-launcher,flamethrower` (the mock's version is
`tools/mock_shots.py`), against a server give the character guns first.

## Looks

Settings → Graphics → **Look** (`[graphics] look`) sets how the world is lit, tonemapped and
coloured (`client/scripts/world/looks.gd`):

- **Factorio** (the default): matched to Factorio's own picture of the same scene
  (`tools/look/factorio_reference.py`). Linear tonemapping; the sun held where Factorio's shadows
  fall (east and a little south), its shadows as dark as Factorio's; no sky reflection on the
  ground or grass (it was what washed the colours out); a fill light from the camera's side on
  models, as Factorio's sprites are lit; and Factorio's own colour lookup for each planet and time
  of day, read from the install (`core/graphics/color_luts`, `space-age/graphics/lut`; Nauvis by day
  is Factorio's identity, its darkening at night left to Zenith's light so lamps still light).
- **Classic Zenith**: the look before 0.1.3 (filmic tonemapping, the sun crossing the sky).
- Add-ons' looks (`api.shaders`, docs/ADDONS.md), such as the Cinematic shaders add-on
  (`addons-src/cinematic-shaders`), whose sun really sets: it sinks in the west with long shadows, a
  colour from the air it crosses and a blue hour after it, each planet in its own colours
  (docs/SUNRISE-SUNSET-PLAN.md). Its clouds (0.4.5) read their pattern from a texture the add-on
  colour from the air it crosses and a blue hour after it, each planet in its own colours.
  From 0.5.1 its noon sun stands in the north-west, the side Factorio's sprites are lit from, rising in the
  east and setting in the west across the north (the look's `sun_noon_yaw`), so models show the camera a lit
  side and a shaded one; Zenith's own noon sun, high behind the default view, lit every side the camera sees
  and drew the modeller's rocks flat. Its setting "Noon sun from the north-west" off gives the old sun back.
  Its clouds read their pattern from a texture the add-on
  draws once when it starts (`shaders/cloud_field.gdshader`, a 1024 x 1024 viewport of 16-bit floats,
  the pattern repeating every 1,800 tiles or so) instead of working the noise out on every pixel and
  every step of the sky's march. From 0.6.0, **Volumetric clouds** (on by default) combines that weather/type
  map with seamless `32 x 32 x 32` 3D Worley volumes inside a curved-horizon shell (`210–390` tiles) with
  sun self-shadowing, Beer-Powder scattering, silver linings, and **Cloud quality** (`Low`/`Medium`/`High`,
  18/28/40 steps); switching **Volumetric clouds** off or passing `--volumetric-clouds=off` keeps 0.5.3's
  lighter flat cloud layer.
  From 0.6.2 a lightning flash (Immersive Weather's, `api.weather` `flash`) lights the look's clouds and
  the sky behind them in proportion to their own brightness (about 2-4x on a stormy night, as the Factorio
  look's sky), capped, so a strike no longer turns the whole sky white under the look's exposure, AgX and
  film curve; the bolt itself is unchanged and the add-on's **Flash brightness** still scales it (0: none).
  `--cinematic-flash=old` keeps 0.6.1's fixed 0.75-0.8 added to every cloud.

A look's passes are drawn before anything else of their render priority (whatever the camera's
distance from the world's origin, where their quad sits). They read Godot's one copy of the screen,
taken before the transparent pass, so blended things drawn after them (smoke, ghosts, icons, and the
flat ground clutter and raised grass, which are blended) keep their own colours: under the Cinematic
look they get neither its grade nor its cloud shadows.

The Factorio look's ground has no sunset (Factorio's has none); from low down its sky shows the sun
going down, restrained, while the light stays where Factorio's shadows fall.
`--sky=<planet>@<daytime>` holds a time of day with Factorio's darkness for it, for screenshots.

`--look=<id>` uses a look for one run (`factorio`, `classic`, `cinematic-shaders/cinematic`);
`--look-file=<file.json>` adds looks from a JSON file, for trying values without an add-on.

A modeller's metallic-roughness picture's metal is drawn as paint: at 0.1 of it, the share part colours
and textures without such a picture get (`factorio_material.gdshaderinc`, the global
`f3d_look_texture_metal`), as far merged chunks already drew it. In full, metal shows only the sky's
reflection, which Zenith keeps dim and blue, so those models read dark and blue. The old drawing is kept:
`--texture-metal=full` for one run (`=paint`, or a share 0-1). The command line wins over the look's
`texture_metal` key (looks.gd, default 0.1). The menu and the model preview
draw 0.1 (project.godot). Factorio's own sprite pack has no metallic-roughness picture;
FUE5 (`tools/models/bake_fue5_pbr.py`), Wube3DP's non-rigged, non-belt models (`tools/models/bake_pbr.py --pack wube3dp`), and Placeholders' non-Zenith, non-rigged models (`tools/models/bake_pbr.py`) do (model_textures_test.gd checks all built-in packs).

Per-model shading: pack.json's `"shading_models": {"transport-belt": "factorio", "iron-ore-*": "pbr"}` (prototype
names, `*` wildcards, or `"items/<name>"` for items; `"pbr"` or `"factorio"`) sets single models over the pack's `"shading"` (model_packs.gd
`model_shading()`, read by `pbr(path)`, so the world, belt items, far chunks, inserter hands, item models, the Model
packs preview and the menu backdrop all follow). An exact name beats a pattern (the first that fits, in file order);
`<name>-<n>` variants follow their base unless named; an `items/` copy checks `"items/<name>"` before bare `<name>`. Only
the Factorio sprite pack (`builtin:factorio`) ignores it; FUE5 (`builtin:fue5`) uses `"shading": "pbr"` (`--fue5-pbr=off`
draws FUE5 Factorio's), Wube3DP (`builtin:wube3dp`) uses `"shading": "pbr"` with `"shading_models"` keeping rigged
creatures, the character, and belts on `"factorio"` (`--wube3dp-pbr=off` draws all of Wube3DP Factorio's), and
Placeholders (`builtin:placeholders`) uses `"shading": "pbr"` with `"shading_models"` keeping Zenith-covered models, their directional siblings, rigged creatures and Zenith-covered items on
`"factorio"` (`--placeholder-pbr=off` draws all of Placeholders Factorio's); `--pack-shading=factorio` still draws every model Factorio's. Rebuilt `placeholders/assembling-machine-{1,2,3}.glb` also win over Wube3DP/FUE5 by default (`--assembler-models=old` restores pack-order priority, letting Wube3DP supply `assembling-machine-1`).

Default model choices (0.3.1): a settings file without `[model_packs] choices` gets the owner's own
(`settings.gd DEFAULT_MODEL_CHOICES`): `big-biter`, `big-spitter` and `biter-spawner` from Placeholders (its rigged ones,
over Wube3DP's by the order), `lab` and `pumpjack` from FUE5, so a new player sees what the owner sees. Saved choices,
`{}` too (the Model packs window's reset saves it), stay the player's; nothing is added to them.
`--default-model-choices=off` gives a file without `choices` none, the pack order alone, as before 0.3.1.

Packs' own shading (0.2.2): a pack whose pack.json says `"shading": "pbr"` (model_packs.gd `shading()`;
Vasillo's, written by `tools/models/fix_pack.py` from `fixes/vasillo.json`'s `pack_json`) has its materials
drawn as their files say (`factorio_material.gdshaderinc` `modeller_tex`, set by model_library.gd
`_factorio` on the materials Load marks `PACK_PBR_META`): no `part_light` balance on its pictures but the
look's `texture_light` ((1, 1) by default, Cinematic too), Godot's SPECULAR 0.5, its own roughness and metal
(metal at the look's `texture_metal` share), its occlusion picture as ambient occlusion only
(the baked vertex occlusion keeping its 0.3 share of direct light), and a normal-map frame right whichever way `dFdy` runs. Its pictured items take the
same lit path (`item_pbr.gdshaderinc`, in item.gdshader and belt_lane_model.gdshader; the Model packs preview
draws the file's own material), and far chunks bake it the same way (far_chunks.gd: no part colour share,
`texture_light` baked in by the vertex's facing; a bake made under the other setting is redone when next
merged). Since pbr-standard step 2 that is every material of such a pack, not only those with a base colour
picture: one without draws its factors as the file says (pc 1, no part colours, no weathering, metal at the same
share), and is never merged into another's row (model_library.gd `Load.textured`); far chunks bake its factor the
same way. This is decided when the model loads (with packs' own shading on then; a change in Settings reaches
these when they next load). `--pbr-untextured=off` keeps 0.2.2's: only pictured materials, the rest by Zenith's
material classes. Since pbr-standard step 3 such a pack's metal is drawn in full (the look's `pbr_metal`, 1 by
default; the global `f3d_look_pbr_metal`, used in place of `texture_metal` on its materials and items) and
reflects a neutral surrounding instead of the planet's blue sky: `shaders/pbr_env.gdshaderinc` writes Godot's
`RADIANCE` (which replaces the sky's sample before its BRDF, energy compensation and specular occlusion), an
upper half of the ambient plus the look's `pbr_env` (0.45 by default) of the sun, as sky.gd and the look light
the moment, a lower half at 0.45 of it, blended over a width growing with roughness (looks.gd `pbr_env_now`, the
global `f3d_pbr_env`, linear; its alpha is the switch). The menu and the model preview reflect the Factorio
look's noon value (`Looks.PBR_ENV_REST`, project.godot). The preview's pictured items, a StandardMaterial3D,
draw their metal at the same share and reflect the preview's own sky. `--pbr-env=off` reflects the sky as before,
`--pbr-env=<0-2>` sets the sun's share for one run, `--pbr-metal=0.1` (or `=paint`) draws metal as 0.2.2 did with Settings' "As paint" (the default; 0.2.2 drew it at 1 on "Full, as before", so `=full` for those players);
`--pbr-env=off --pbr-metal=0.1 --pbr-untextured=off` together are 0.2.2's drawing of a pbr pack. Built-in packs
never write `RADIANCE`. Far chunks still draw a pbr pack's metal as paint.
Since pbr-light-balance such a pack is lit by direction, so the sun decides its light and shaded sides: its share of
the look's fill light from the camera is the look's `pbr_fill` (0.3 by default) and of the ambient `pbr_ambient` (1),
the ambient comes through Godot's `IRRADIANCE` from the sky above to 0.35 of it below, and the neutral reflection's
sun share comes from a broad lobe towards the sun (none from straight opposite) over the same sky-to-ground ambient
(`shaders/pbr_env.gdshaderinc`; the globals `f3d_pbr_light` (on, fill share, ambient share), `f3d_pbr_sky` (the
ambient, linear) and `f3d_pbr_sun` (towards the sun), looks.gd `pbr_light_now`, set each frame). On buildings,
items and belt items; far chunks keep the flat balance. Measured lit-to-shaded in the Factorio look at noon
(ui_test.gd `_pbr_light`, a window, `--pbr-light-models=<pack folder> --pbr-light-shots=<dir>`): a matte sphere
2.16 -> 4.54, the modeller's drill 1.63 -> 4.69, his rock 1.08 -> 2.90. `--pbr-light=flat` gives the flat balance
back for one run (the fill and ambient in full, the reflection the same all round); the menu and the model preview
are always flat (no sun there). In a dev build the debug menu's Lighting tab has sliders for these numbers (fill, ambient,
the reflection's k, the sun lobe 2.8, the downward ambient 0.35, the metal share, flat/directional), live, nothing saved, with Reset and
"Copy values" (prints them to the log; global `f3d_pbr_tune`, looks.gd `pbr_tune`). Below them the same tab moves, live and unsaved, SSAO and SSIL (on/off, radius, intensity, power, detail, light affect, horizon, sharpness), the contact shading's strength and rim and patch widths, the sun's energy, shadow softness and biases, and the ambient energy: each shows what the game has now (a look or a quality change still moves it) until dragged, then is kept over the look each frame (looks.gd `light_tune`) until its Reset. A pbr pack's extra light follows the sun and ambient these sliders set (looks.gd reads its globals after them): the neutral reflection's sun lobe and sky parts and the ambient by direction from the sun's and the ambient's energy and colour now, the fill (`model_fill` x `pbr_fill`) by the ambient's energy over the game's (`f3d_pbr_light.w`), so at sun 0 and ambient 0 a pbr model is black but for its emission and lamps; untouched, nothing changes. `--pbr-light-scene=off` reads them before the sliders as before (the sliders then don't reach a pbr model's extra light). The Factorio sprite pack stays `factorio` (FUE5 uses `"shading": "pbr"` or `--fue5-pbr=off`; `Wube3DP` and `Placeholders` use `"shading": "pbr"` with `"shading_models"`, or `--wube3dp-pbr=off` / `--placeholder-pbr=off` for `factorio`),
No model gets a camera fill any more (owner: every model, tree, item, belt item and far chunk lit by the scene's sun and ambient alone, so at sun 0 and ambient 0 everything is black but emission, lamps and the UI): the look's `model_fill` (the Factorio look's 1.1) is off by default. `--model-fill=on` brings the look's own back for one run (0.2.2's, faded by night), `--model-fill=<number>` puts that fill on every look, `=off` none; the Lighting tab's Camera fill slider (from 0) sets it live. Whatever fill there is follows the ambient slider (now over the game's), and the sky's own colour, haze and clouds follow the ambient slider and its sun the sun slider (planet_sky.gdshader `scene_light`; `--pbr-light-scene=off` leaves both as before).
as is a pack without the key. The old drawing everywhere:
Settings > Graphics > Advanced > Packs' own shading, Factorio's everywhere (`[graphics] pack_shading="factorio"`),
or `--pack-shading=factorio` for one run (`=pack` the other way); the command line wins over the setting.
They set the global `f3d_pack_shading` (looks.gd `apply_pack_shading`: at the app's start and whenever the
setting changes, from main.gd, game or not, so the menu's model preview follows; in a game also in `settle()`
and when the game's look goes; project.godot's default is 1).

Since lighting-fixes step 1 the scene's light is the only light: the sun, and one lighting environment that every
material takes its ambient light and reflections from (buildings of every pack, items, belts, ground, trees, water,
far chunks). It lives in the sky's cubemap: in a game `planet_sky.gdshader` draws, in its `AT_CUBEMAP_PASS` only, an
upper half of the ambient (sky.gd's colour times the energy the look and time of day give, linear), a lower half of the
ground's albedo (look key `env_ground`, `Looks.LIGHT_ENV_GROUND` 0.25/0.23/0.19) times the sun on flat ground plus that
ambient, and a soft horizon; optionally a wide glow towards the sun (`env_glow`, none by default). The camera still sees
the planet's sky as before. Godot's ambient is held on that sky (`ambient_light_source` SKY, contribution 1,
`reflected_light_source` SKY) each frame while a look is on, the look's own values coming back when it goes; a look that
asks for sky ambient (Cinematic at twilight, 0.5) gets that share of the drawn sky in the upper half. The cubemap is 64
(32 before) and still updated a little each frame (incremental). In space the lower half is half the ambient. Night
vision's lifted ambient reaches it (main.gd puts it again after). "pbr" packs' own `RADIANCE`/`IRRADIANCE` terms
(`pbr_env.gdshaderinc`, below) step back (global `f3d_light_env` 1); the menu and the Model packs preview keep them.
`--light-env=shader` gives 0.2.2's light for one run: a constant ambient colour, the planet's sky in reflections,
"pbr" packs' own terms, the looks' 0.2.2 ambient (`looks.gd put_light_env`, `light_env_switch`). Measured in a
window with ui_test.gd `_light_env_window` (`--light-env-models=<pack folder> --light-env-shots=<dir>`).

Since lighting-fixes step 2 the shade is lit by the scene's ambient, not per pack: a look's `ambient_energy_lit` is its
ambient multiplier by day under the lighting environment, moving to its `ambient_energy` by night (nights as before):
the Factorio look 0.7 (0.36), so flat ground is about 4-5:1 between sun and shadow as Factorio's own ground is
(measured at noon, ui_test `_light_env_window`: 6.0:1 on screen before, 3.87 with 0.8, so 0.7); Cinematic 0.9 (0.42):
5.85:1 sun to ambient in scene light (11.4 before), 8.7:1 on screen (15.6 before).
`--light-env=shader` keeps 0.2.2's ambient with 0.2.2's light.

Since lighting-fixes step 4 a look's `roughness_min` (Cinematic's 0.55) holds only built-in packs and icon-coloured
items: a "pbr" pack's surfaces and a modeller's item models keep the roughness their files give (the globals
`f3d_look_roughness_min` and `f3d_look_roughness_min_pbr`, 0; Godot's roughness limiter and Cinematic's bloom
luminance cap still damp the sparkle). `--pbr-rough=floor` puts the look's floor on them too (0.2.2's on buildings).
The sun's highlight (`light_specular`) is 0.5 in the Factorio look (0.25 before) and 1.0 in Cinematic (0.6 before);
`--sun-specular=<0-2>` sets it under every look for one run (`=0.25` with the Factorio look is 0.2.2's).

Since lighting-fixes step 5 (Cinematic shaders 0.5.2, defaults updated in 0.5.3) the Cinematic look's ambient occlusion
acts on indirect light: `ssao_light_affect` 0.15 (Zenith's own looks 0.85) and the look key `ao_direct` 0, which
scales the models' and the ground's own occlusion share on direct light (global `f3d_look_ao_direct`:
factorio_material's `AO_LIGHT_AFFECT`, terrain's `ssao_on_sunlight`; 1, as before, in every other look); radius 1.7,
intensity 2.45 and power 2.0 (1.75, 1.75 and 1.6 in 0.5.2; 1.4, 1.5 and 1.6 before), SSIL off by default as before.
The add-on's setting "Occlusion in sunlight too" (off by default) also enables occlusion in direct sunlight.

Since lighting-fixes step 6 the Model packs preview (and the in-game model chooser's) and the main menu's backdrop are
lit as a game is: the Factorio look at noon on Nauvis (`looks.gd noon_rig`: sky.gd's noon sun and ambient times the
look's, its held sun, ambient_energy_lit and tint, the lighting environment drawn into the sky's cubemap for ambient and
reflections, linear tonemapping at 0.9, the sun highlight 0.5; `put_noon_rig`), and with no game on the globals
`f3d_light_env` 1 and `f3d_look_ground_specular` the look's (`put_idle_globals`), and the look's fill light (step 3,
`put_noon_fill`) from the camera's side. The preview's corner's lamp button gives the studio light before (a key from the upper left, a fill, a grey sky in
reflections, filmic) while the window is open; `--preview-light=studio` makes that the default for the preview and gives
the menu's backdrop its late-afternoon light (filmic, colour ambient) as before.

Since lighting-fixes step 3 the Factorio look has a fill light (look key `fill_light`, 0.35): a second DirectionalLight3D
(`looks.gd fill_light`, made in `attach`) with no shadow, the sun's colour, a low highlight (0.25), from behind the
camera 35 degrees up and 20 to its right (it follows the camera's turn), faded out by night, none in space, on
everything but the ground: terrain and water, flat decoratives and their grass are on `Visuals.GROUND_LAYER`
(render layer 17), which its cull mask leaves out, so the ground's light and shadows stay the sun's and the ambient's
while what stands on it has its shaded fronts lifted, as Factorio's sprites are rendered with a fill. Other looks have
none. `--fill-light=off` gives the look without it (the light before), `--fill-light=<0-4>` that energy under every
look. The camera fill on model materials (`model_fill`, `--model-fill`) is unchanged and still off by default.
Measured in a window (ui_test `_light_env_window`, Nauvis noon): flat ground 4.43:1 lit to shadow with or without it
(the ground's light unchanged to 4 digits); the built-in assembler 7.59:1 without, 4.10 with 0.35 (3.51 with 0.5);
Vasillo's drill 3.32, 2.69; iron ore 4.61, 2.65.

The standard PBR reference set: `tools/models/make_pbr_reference.py` writes `client/tests/fixtures/pbr_ref/`
(39 one-tile spheres, plates and a tube, one glTF material input each: metal and roughness as factors and as
pictures, a tinted base colour, normal maps, occlusion at two strengths, emission, alpha, samplers, a texture
transform, a second UV set, vertex colours; a `.gdignore` keeps them out of Godot's import). model_textures_test.gd
`_pbr_reference` loads each as a "pbr" pack's model and checks the shader parameters it sets, and pins what Godot's
glTF reader does (no occlusion strength; a texture transform read for the base colour only). In a window,
two ui_test.gd sections (`-- --pbr-ref-shots=<dir>` saves the pictures): `--only=_pbr_look`, metal against paint
spheres in the Factorio look, which prints the parity k ("parity k"), and `--only=_pbr_reference`, the strict
pass, which draws each file by Zenith and by Godot's own StandardMaterial3D at the same place (fill 0, metal in
full, the neutral reflection off; mean within 2%, no block over 5% apart, the known differences listed in
`PBR_REF_DIFFERS`); `-- --pbr-ref-rows=alpha_mask,normal_east` draws only those rows. Godot's side is given the
MikkTSpace tangents glTF asks for (Godot's runtime glTF reader leaves a file without tangents with one fallback
tangent, so its normal maps leant the same way whichever way the UVs ran; headless, `_pbr_reference` checks that).
Each section takes about 6 frames a picture after 30 to settle, and prints its time and frame rate.

A "pbr" pack's cut-out material (glTF MASK, Blender's Alpha Clip) that its file marks single-sided (doubleSided
false, Backface Culling on in Blender) drops its back faces and their shadows, as Godot's own material does
(`clip_one_side` in `factorio_material.gdshaderinc`); a double-sided one, and every other pack's cut-outs, draw
both sides as before. `--pack-shading=factorio` turns it off with the rest of packs' own shading.

A pack whose belt is narrower than Factorio's can say how far in its items ride: pack.json `"belt_lane_offset"`
(tiles from the belt's centre line; absent: Factorio's 0.234; never wider than that). Items on belts that pack's
belt model draws are drawn on lanes moved in to it, each lane towards the centre line (straights, curves,
undergrounds, splitters, the packed lanes, the far lanes' icons);
the belt simulation's positions are untouched. Vasillo's belts say 0.21 (rails 0.375 out, a plate turned 0.35 rad
reaches 0.16 sideways). `--belt-lane-offset=<tiles>` overrides the pack for one run.
`"belt_item_height"` is the height of the belt surface the items rest on (absent: the belt model's top plus 0.02, 0.03
for the far lanes); an item model's lowest point sits on it. Vasillo's belt surface tops out at 0.25 on every
belt, curve, underground and splitter. `--belt-item-height=<tiles>` overrides the pack for one run.

The character's flashlight at night (avatar.gd) is Factorio's cone: its own picture
(`core/graphics/light-cone.png` from the install, or one drawn to its measure without one), 25 tiles
long from a tile ahead of the character, fading out, landed on the ground through a spot light 10
tiles over the character. Nothing casts that spot's shadow (its shadow stays on only because Godot
projects a spot's picture through the shadow's matrix), so buildings don't stop the beam, as none
stops Factorio's light, and its shadow pass draws nothing. In first person it turns to where the
crosshair looks, whichever way the body faces. `--flashlight=old` brings back 0.2.1's: a spot 3
tiles up whose shadows the buildings cast, so its beam ended at the next building. The Compatibility
renderer, which draws no projected pictures, always has the old one.

The belt step-up (avatar.gd, owner: "doesn't move camera or actual player position, just a visual
thing"): standing on a belt, underground belt, splitter, loader or linked belt (the belt family of
Factorio's walk-over types, stand_height.gd's BELTS), the character's body is drawn on its top (the
model's, else its placeholder's: 0.15 tiles for a belt), at most 0.3 tiles up (avatar.gd STAND_MAX: a
splitter's or a tall loader frame's top isn't stood on); pipes-to-ground, heat pipes and rails are walked
past at ground level. Eased up in about 0.1 s and down a touch
slower. Drawn only: `position`, reach and every command stay the game's, and the camera never follows
it (the first-person eye and the angled view's centre follow only add-on lifts set with `camera`).
The body, shadow, lantern, health bar, muzzle, flames and step sound follow it. The stand height is
looked up only when the drawn position moves (at most once a frame), never standing still.
**Graphics → Step onto belts** (on) turns it off; `--belt-step=off` turns it off for a run whatever the
setting says.

Add-ons' camera modifiers (add-on API 1.7, `api.camera.set_modifier`: a bob, sway, shake or FOV kick,
summed and capped, drawn on the angled view, Factorio's view and first person only; walking, reach and
picks' range never follow them) are off for a run with `--camera-modifiers=off`: the camera as without
any. An add-on's `take({"input": false, "aim": "center"})` aims building, mining and the hover at the
middle of the screen, as first person does.

A lit lamp's light (lamp_lights.gd) reaches 18 tiles with a soft fall-off (Godot's omni attenuation
0.42), while the 2D HDR lightmap extends the ground light pool out to 22 tiles (near lamps get an
outer ground-spread splat beyond the 3D light's grazing fall-off so flat terrain lights smoothly
wide as Factorio's 40-tile lamp pool); a coloured lamp's reaches 10.3 (`OmniLight3D`) / 12
(lightmap). `--lamp-radius=old` brings back the old reach (range 7, attenuation 1). Detailed 3D
`OmniLight3D` lamps (64 / 128 / 224 at Level of detail Low / Medium / High) and furnace, boiler and
lab fire/glow lights (`working_glow.gd`, 16 / 32 / 48) scale their reach with
`far_chunks.detail_distance()` and prioritize lights inside the camera frustum. Beyond the detailed
zone, **Settings > Graphics > Far lamp lighting** (on by default) splats remaining lamps and glows —
including distant powered lamps carried as lightweight snapshot hints (`extra.lp`/`extra.lc`) out to
View distance — into a 512x512 HDR 2D lightmap (`f3d_lamp_light`) sampled directly by terrain,
buildings, far merged chunks, trees, water, decoratives, and Distant Horizon LODs with smooth
cross-fading across the LOD boundary; `--far-lights=old` restores the fixed 48-light behaviour with no
lightmap.

Rail signals and chain signals (`signal_lights.gd`) also draw soft additive camera-facing glow beacons
(`signal_glow.gdshader`) and
2D lightmap splats in green / yellow / red / blue (from live `st` or snapshot `extra.sg` past
`focus.r`) under **Far lamp lighting**; pooled `OmniLight3D`s (16 / 32 / 64 at Low / Medium / High) are off by default (`--signal-omni-lights=on` restores them), and `--signal-lights=off` disables rail signal distance glows
and lights.

Cars, tanks and spidertrons have their own headlights (vehicle_lights.gd), Factorio's oriented
`light`s from base's prototypes: the car two cones 0.6 tiles either side and 14 ahead in a warm
yellow, the tank two 0.1 either side, a little splayed and brighter, the spidertron four of different
sizes and splays and a round light. Each is the flashlight's cone, scaled to its size and placed
where Factorio shifts it, so a car's two overlap into a beam about twice as bright and a little wider
than the character's. They shine at night (above darkness 0.3) on the vehicle the character drives
or rides in (the bridge doesn't say who drives the others), and meanwhile the character's lantern
and flashlight are out, as Factorio draws nothing of a character in a vehicle. `--vehicle-lights=off`
puts back the old way: no vehicle lights, the character's flashlight shining out of the vehicle.
Vehicles others drive light too: a car, tank or spidertron that has moved in the last 30 seconds has
a driver, so its cones shine as ours do (at most 6 besides ours; no shadow-casting lights), and each
lamp shows a glare, an unshaded card at the lens that is bright looking into the lamp and only a small
lit spot from the side, so a vehicle driving at the camera at night reads by its lamps.
`--headlight-glare=off`: as before, only the vehicle the character is in lights, no glare.
`--headlight-storm=off`: the lamps go by the game's darkness alone; by default a weather that dims the sun
(a thunderstorm's `sun_energy_scale` 0.4) also lights them, as the screen looks like night (e.g. dusk in a storm).
`--vehicle-anim=old` disables enhanced car/tank chassis suspension and engine rumble, front fender
steering (`anim_steer_front`), the car's spinning engine fan (`anim_engine_fan`), emissive
headlight meshes (`anim_headlight`), closed-loop 32-cleat caterpillar tracks with differential pivot
turning (`anim_tread_l`/`anim_tread_r`), independent gun barrel/coax recoil + cannon hull kick, and
vehicle exhaust/dust particles, keeping only basic wheel rolling and the old linear tread slide.
`--vehicle-tracks=off` disables persistent ground tread tracks (ribbed caterpillar cleats for tanks,
chevron tire treads for cars) and GPU-simulated ballistic dirt/mud clods and churning dust plumes
kicked up by moving or pivoting vehicles.

`python tools/look/factorio_reference.py [--looks factorio,classic]` makes a map, has a Factorio
window save its picture of a small scene at noon, takes Zenith's of the same place in Factorio's
view (F6) once per look on a headless server with the bridge (Zenith's default settings), and
compares the ground's colour, saturation and contrast (git-ignored `art-src/look/`). It adds and
removes a `steam_appid.txt` beside factorio.exe for the run, as `hybrid_cost.py` does.

## Decoratives

Grass, flowers, small rocks and decals lie on the ground as in Factorio, with the pictures from
your install (which picture each has is in `client/data/decoratives.json`, written by
`tools/decor_index.py` from `factorio --dump-data`; CI regenerates it and prints it when it
differs). Gleba's plants, corals and icebergs (Factorio's "object" layer) stand up as cards.
Settings → Graphics → Decoratives turns them off (`[graphics] decoratives=false`; the client then
stops asking for them, `dc` in the hello), and Decorative density draws a share of them (the
same ones each time). They are drawn round the character (or the remote view's point) out to
Decorative distance (64 to 320 tiles, default 192): all of them to 80 tiles, then half, then a
quarter past 136. The bridge sends a chunk's decoratives again when a tile is placed or mined in
it or something is built there; ones another mod's script removes stay drawn until the chunk's
next refresh.

Settings → Graphics → 3D grass raises grass and low plants near the character (off in the Low
preset): the same pictures on a small grid, tufts arching from their root and bushes rising where
the picture is thick, no shadows of their own, the flat picture left under them as their shadow.
Carpets (the wide patches of short blades most of a Nauvis meadow is) stand up as clumps of blades:
crossed cards, each a half-tile piece of the patch's own picture where it has plant, about half a
tile tall, cut out with alpha to coverage, bent by gusts from a drifting noise texture; further from
the character fewer stand. From Factorio's angle they cover what the picture shows; they fade back
into the flat picture over the range's last 10 tiles and as the camera zooms out. A chunk raises at
most 106,496 triangles' worth, tufts and bushes first and carpets from what is left: a real Nauvis
meadow (600 to 1,400 decoratives a chunk) raises nearly all of them. `-- --grass-stats` prints what it takes every
5 seconds, with the frame's GPU time and triangles.

When the camera isn't Zenith's own view round the character (an add-on's camera such as the
Cinematic camera's F8, first person, the remote view), the camera drawing leads instead
(client/scripts/world/view_priority.gd): 3D grass is centred half its range ahead of the nearest
ground the camera sees, gliding as the camera turns and fading down and up again across a jump
longer than the range; and Items in 3D's cap counts only the belt items in the camera's view (3
tiles' margin at its edges), nearest the camera first, the rest drawn as icons (both records paths,
GDScript and BeltDrawNative; the lattice's packed lanes are icons under any cap, as before). The bridge's
square of belt items already follows an add-on's shot (its focus), so nothing more is asked for.

## Trees and rocks

Nauvis's trees grow in Factorio's variations (`client/scripts/world/nature_looks.gd`, from
`client/data/nature_looks.json`, which `tools/models/nature/tree_looks.py` measures from the
sprites in your install): each tree picks one of its prototype's 8 to 12 pictures by Factorio's own
weights, by where it stands, and its model is scaled to that picture's height and width (the young
ones about 70% of the tallest), or, for the two fallen ones six types have (about 1 tree in 87),
laid on the ground at the picture's length. Each tree takes one of its prototype's leaf colours,
as Factorio tints its trees. Rocks take the size of one of their 16 to 20 pictures. The bridge
doesn't send which picture Factorio drew, so a given tree may differ from Factorio's; the mix is the
same.

With a Factorio install, the leaf cards wear patches of the tree's own leaves picture (a 4 x 4
atlas made on a worker thread, about 60 ms a tree type), its leaves' light and shade over the
model's own lighting; bark and rock take the grain of their own pictures, read along the three
axes in the model's space (one 64 x 64 layer each in a texture array, `f3d_nature_grain`). Without
an install the shader cuts its own leaves and the materials stay plain, as before.

Switches (client, after `--`): `--nature-looks=off` (one shape and colour per prototype, +-10%, no
grain or atlas, as before), `--leaf-atlas=off` (the shader's own leaves), `--nature-grain=off`.
`python tools/models/nature/raster.py out.png tree-05:atlas big-rock:atlas` draws a model beside its
sprite from Factorio's camera in plain Python (no Blender, no window; `NAME@k` places a variation
as the client does), for looking at shape and colour; the client's own look needs a screenshot.

## Creatures' skins

Enemies wear Factorio's colours from their sprites (`tools/models/creature_skin.py`,
`tools/models/space_skin.py`, `client/scripts/world/creature_models.gd`). Worms, Nauvis's spawners and
Gleba's wriggler keep Factorio's one mask layer per vertex, which each tier's tint colours; where the
mask doesn't reach (a worm's head and mouth, a spawner's egg sacs, much of a dead worm) the skin tool
writes white, which the shader reads as no mask, so those parts keep the sprite's own colour. Factorio
draws no glow on its enemies: a demolisher's lava is painted bright in its sprite, so its model's lava
shines by its own colour, 0.4 of it (`PAINT_GLOW`): about the sprite's brightness by day, not dark on
its shaded side; the crust over it doesn't glow. `--creature-glow=old` (client, after `--`) brings back
0.2.1's look: the unmasked parts in the tier's colour four times over (lime, cyan, red on worms, red and
orange spots on spawners) and the lava at its model's 2.5 times red. Organic creature surfaces (chitin and flesh)
also carry procedural 3D micro-bump, roughness breakup, and damp-organic rain wetness without roof puddles or
ripples (`factorio_material.gdshaderinc`, `weather_surface.gdshaderinc`); `--organic-surface=old` disables those.

## Chunk streaming: the view's direction, the area cache

(I18, owner: "direction based chunk culling and faster stream in time; maybe we cache everything in an
area".) Not run in a window or measured yet: only the mod, mock and protocol tests ran.

- **Direction.** The client works out the view's direction (where the camera looks on the ground,
  turned towards where the character moves; none looking straight down, as in Factorio's own view) in
  eight steps, and asks for the chunks of its square in that order: a chunk behind the view counts as
  further away, straight behind as twice its distance (world.gd `prio_order`). The bridge orders its
  queue the same way (`sub` `f`), and the client builds dirty chunks and meshes ground in that order,
  hidden chunks last. A screenshot's cover keeps its own order (no direction while it loads).
- **Hidden behind the camera** (client/scripts/world/behind_cull.gd): chunks of the square outside the
  camera's view laid on the ground (grown by 64 tiles, more at the far end), outside the ground whose
  shadows can fall into the view, and more than two chunks from the character are hidden, their nodes
  kept as they are: turning back shows them again the same frame, nothing rebuilt. Off in the remote
  view, while chunks are held, while a screenshot loads, under full detail, in VR, and while another
  camera draws the world (a train's view, the train overview, an add-on's screenshot view).
  `-- --no-behind-cull` turns it off; `-- --tight-cull=off` restores legacy view/shadow/item culling bounds instead of the tight ground-slab frustum culling; `-- --behind-cull-hide=all` hides every off-view chunk in the same
  frame instead of slicing off-view hides across frames (`HIDE_PER_FRAME`); `-- --behind-cull-show-slice=off` shows all newly in-view chunks and emits visibility signals in one frame instead of keeping a 3-chunk collar immediate while slicing far reveals.
- **Faster.** The bridge starts up to 4 chunk snapshots a tick (the Chunk snapshots per tick setting
  is the least) while the work budget has room; each further one only while its slices fit the
  chunks' share of the tick, so the UPS governor's budget still bounds it. Moving, the client asks
  for 12 chunks at a time (8 before) and asks for more once half of them are drawn, not only every
  0.15 s.
- **The area cache.** Chunks that leave the square stay built and drawn, as they last were (the bridge
  no longer updates them), up to 4 chunks past it, at most 600 (fewer at long view distances, under
  the same total as held chunks), the least recently left going first and those hidden behind the
  camera before those in view. The bridge tells the client (hello `lv`, message `kept`) the change and
  entity counts each chunk had when it left, if nothing changed there since; walking back, such a chunk
  is asked for at once with those counts and stays drawn, and the bridge's `same` needs nothing rebuilt.
  Further out the cache of chunks' messages (1,500 chunks, now also at most about 192 MB, least
  recently used first) answers as before; a chunk that got changes (`add`, `del`, `upd`, `tiles`)
  while it was in view is no longer offered from its old messages (the bridge would refuse them), but
  is confirmed by `kept` when nothing changed.
- **Letting go after a screenshot** (L14). A shot zoomed far out (F12, `api.view.screenshot`,
  `--full-shot`) loads every chunk its camera sees, thousands; when it ends the view's own subscription
  goes out at the next step and the rest are let go. An unloaded chunk is now hidden first, farthest from
  the focus first, as many a frame as the unload slice (frame_budget.gd `unload`, 1.5 ms) holds, and its
  records and nodes go after it as before; before, each stayed drawn until its records had gone, 2-3
  chunks a frame, so the renderer kept drawing thousands of chunks at full detail for half a minute.
  Their clutter (decoratives.gd's sweep every 2 s) is dropped and freed 1 ms a frame each, hidden as it is
  dropped; the sweep's one frame had dropped 4,000 chunks' (30 ms) and queued their 32,000 nodes to be
  freed together (95-100 ms). `-- --unload-hide=off` keeps the chunks drawn until their records have gone
  and drops the clutter in the sweep's frame, as before. And Hold the game at
  60 UPS takes no step while full detail is on (the shot's slow ticks, the bridge in photo mode and the
  game held for the picture, had taken its whole ladder, FPS limit 45 and view distance 5 included, which
  came into force the moment the shot ended and came back a step every 5 s); it judges afresh 10 s after.
  `-- --governor-full-detail=judge` judges the shot's ticks as before. The bridge side was already spread:
  the chunks dropped are noted and told as `kept` 16 a tick (world.lua `kept_step`; the mock does the
  same now, where it counted all 4,000 at once and stalled past the client's timeout).
  `--stutter-probe=<out.json>@shot` measures it (below): headless against the mock's `--busy` base, a
  4,708-chunk shot letting go of about 4,300, the 10 s after it went from 447 frames (45 FPS under the
  governor's limit for 16 s; 40 over 33 ms, 1 over 50 ms, the worst 117 ms) to 601 (6 over 33 ms, 1 over 50,
  the worst 53 ms), and the chunks let go were all hidden 0.3 s after it instead of 28 s.

- **Chunk draw lists kept** (`--collect-cache`, on by default; perf-rd-world task 2). A chunk's build keeps
  what its records' pass made (chunk_view.gd `DrawLists`: models' transforms, parts, cards, boxes, rings,
  belts, both what a far merge draws and what it leaves out). A build for the chunk's view alone (far
  <-> near swap, belt stand-ins ready: world.gd `redraw_view`) uses them while nothing they were made from
  changed (the chunk's `draw_rev`, its records, `ModelLibrary.generation`, the pictures' generation, LOD
  quality, the cliff wall and pipeline warm-up switches, and the machine states it read); any other
  rebuild (`_dirty[c] = true`, `redraw`) walks the records again. The far merge's gather reads the same
  lists (far_chunks.gd `fill_from_lists`) and only goes record by record for what they can't hold
  (cargo, belt ends, remnants, ore, placeholders), taking a record's model from the near build's cache.
  Replay bench (`python tools/bench/world_stream.py`, headless, the mock's busy base, 25,700 entities):
  a build for the view alone 7.3 -> 0.33 µs an entity, the far gather 17.6 -> 0.40, a far chunk's first
  build and gather together 27.6 -> 27.4; a near chunk's first build 23.8 -> 27.6 and a build for a change
  7.1 -> 9.4 (it now also notes what the merge would draw); every hash equal both ways.
  `--collect-cache=off`: every build walks its records and the gather reads each record, as before.
- **Records resolved once, native chunk collect** (`--resolve-memo`, `--native-collect`, both on by default;
  perf-rd-world task 4). `--resolve-memo`: a record's model, its readiness and its moving parts come from one
  model_library.gd `resolve_entity` call (one `entity_models()` instead of three, kept per `generation` by the
  model names; only a ready answer is kept), used by the chunk build and the far gather; the record cache also
  keeps the record's contact rings (world.gd `Rec.cache_rings`), so a build for a change appends them instead of
  working them out again. `--native-collect`: with `--collect-cache` on, the records the record cache holds are
  walked in C++ (`ChunkBuildNative.collect_rows`, 512 at a time, the clock checked between) and the rest
  (first builds, cliffs, remnants, ores, cargo, wet drills, covers, belt ends, open underground pipes, a model
  not yet known warm) by GDScript (chunk_view.gd `_walk_rec`) as before; the lists hold the same, only the order
  of a model's instances differs (each still with its own record). `--resolve-memo=off`: the three calls and the
  rings worked out each build, as before (with `--native-collect` on, the records it walks still append their
  kept rings: the same rings, so both switches off for the old path in full); `--native-collect=off` (or a DLL without the method): every record in
  GDScript. Test: `tests/chunk_build_native_test.gd` (collect_rows against `_walk_rec` on random records).
- **A chunk's first build from shape templates** (`--walk-shape`, on by default; perf-w4-walk). With
  `--native-collect` on, a record the record cache doesn't hold yet (a chunk coming into view) no longer always
  goes to `_walk_rec`: a table of shape key -> template (chunk_view.gd `_shapes`) is filled where `_walk_rec`
  fills the record cache, and `ChunkBuildNative.collect_rows` makes such a record's row from it: the transform
  in `ModelLibrary.placed`'s order (bit-equal), the contact rings moved from the template's origin (within float
  rounding), the record cache written as `_walk_rec` writes it. The key (`ChunkBuildNative.shape_key`) packs the
  prototype id, direction, `s`, `u`, `pc`, `pw`, `wc`, `wg`, `el` and the variant the record's `zv` seed picks;
  a record with any other extra key except those known not to change the model (`q`, `w`, `r`, `g`, `d`, `up`,
  `n`, `ai`, `fa`, `fc`, `lp`, `lc`, `sg`), its own pack (`zmp`), a painted train stop, trees, rocks, ores and
  what `--native-collect` already leaves to GDScript still go to `_walk_rec`. The table is emptied when
  `ModelLibrary.generation`, the prototypes or `ModelPacks.version` (or the packs' readiness) change.
  `--walk-shape=off` (or a DLL without `shape_key`): every first build resolved by `_walk_rec`, as before.
  Test: `tests/chunk_build_native_test.gd` (first walk with shapes against `_walk_rec`).

## Mod settings

In a game the client's menu started: the client's Settings → Mod settings, sent over RCON at once.
In Factorio: Settings → Mod settings → Map. On a headless server started by hand, set them from
the server console or RCON, for example `/c settings.global["f3d-chunks-per-tick"] = {value = 2}`.

| Setting | Default | |
|---|---|---|
| Surface to stream | nauvis | Where the server's character lives |
| Chunk snapshots per tick | 1 | The least started a tick: up to 4 are while the work budget has room (I18). Only chunks that must be read count: chunks the client kept (answered `same`) and ungenerated ones (`none`) don't wait for it, so going back to a surface (a Factorissimo building's door, a platform and back) takes a few ticks |
| Bytes sent per tick | 32768 | Caps queued world data per tick. While a screenshot loads its view (photo mode, `photo` in PROTOCOL.md) the bridge sends 4 times this and starts up to 8 chunk snapshots a tick, whatever the setting above |
| Max live-update radius | 192 | Movers and machine states beyond this aren't sent; caps the client's "Entity distance" (Settings → Graphics, default 192). A save keeps the value it had; on a server raise it with `/c settings.global["f3d-max-focus-radius"] = {value = 192}` |
| Moving entity update interval | 2 | Ticks between mover updates |
| Longest wait between searches for moving entities | 32 | The search of the live-update area for movers (6-12 ms every 8 ticks on the owner's save, finding the same few each time: 99% of what movers cost at -62,-26) waits twice as long each time it finds the same movers (by count and unit numbers), up to this many ticks; a search that finds anything else puts them back to every 8 ticks. A mover that appears while nothing else changed (a robot leaving its roboport, a train entering the area) shows up to that many ticks late; the minimap's robot dots come from the same search. 8: every 8 ticks, as before |
| Belt item, ground item and inserter radius | 24 | Items on the ground, inserter hands, fluids, heat, robots' cargo and plants' growth within this many tiles of the camera are sent; 0 turns them off. Items on belts go as far as the client's Belt item distance (Settings → Graphics), which Zenith always sends; this radius is used for them only by clients that don't. Lower it if a dense base costs too much script time |
| Belt item and inserter update interval | 6 | Ticks between updates; the client glides items and arms in between |
| Spread the bridge's periodic jobs | on | The hand-craftable counts (230 recipes, 45-80 ms on one tick whenever the inventory changed, about every 1.5 s on the owner's save), the machine states' search (every animated machine within the focus radius, 20-66 ms twice a second) and the planets' idle looks for spider legs and cargo pods (two area searches, 10-19 ms on the same 30th tick as the counts) run in slices over several ticks (32 recipes a tick; the area in 4 strips, one a tick) and on ticks of their own. The perfbridge round's trace at -62,-26 found these the bridge's biggest single-tick spikes after the belt updates' due tick. Off: as before |
| Starter kit | on | Freeplay items for the bridge's own character |
| Player to play as | (empty) | Whose character the client plays on a server; empty: the player who was online last. `/f3d-player` changes it while the game runs |
| Act as the player for other mods | on | When the client plays a player's own character (single-player, or the player to play as while they're connected), building, mining, rotating, pasting settings and opening machines go through that player, so other mods get Factorio's own player events (`on_built_entity`, `on_player_mined_entity`, `on_gui_opened`...) and Factorio's own reach and placement rules apply. The bridge's own character (no player) always acts by script |

## Add-ons

Add-ons ([ADDONS.md](ADDONS.md)) are folders with an `addon.json`, found at start-up in
`user://addons` (on Windows `%APPDATA%\Godot\app_userdata\Zenith\addons`), in `addons/` beside
the executable (in a checkout, the repo's root), and in any `--addons=<folder>`. The main menu's
Mods window lists them with a switch each (saved in the settings file's `[addons]` section) and
why one wasn't loaded (a newer add-on API than this Zenith's, a broken `addon.json`, an entry
script with an error). The log says which started. Their keys show in
Settings → Controls under each add-on's name; their data is kept in `user://addons-data/<id>/`.
An add-on with the camera turns the player's controls off until it hands it back; Zenith takes it
back itself for a ride to a space platform.

**Timed scenes.** `--cue-tick=<game tick>` names the game tick a filmed scene starts on; add-ons
read it with `api.world.cue_tick()` and the game's tick with `api.world.tick()` (add-on API 1.91),
so what they do repeats the same way each take, held by a pause and slowed with the game. Immersive
Weather's `--weather-strikes=<file>` times its lightning on it (the add-on's README, "Timed strikes";
without it the random storm as before). Its storm wind (0.3.2) is a roar with random gusts made at start;
`--weather-wind=old` (or its setting Audio > Storm wind: Classic) plays 0.3.1's whistle loop instead. Its rain and wind loops are softer from 0.3.4 (top end eased, peaks lower);
`--weather-sounds=original` (or Audio > Rain and wind tone: Original) plays the files as first bundled.

An add-on is a program running with the player's rights, so one nobody switched yet is off until it is
switched on (the switch is the consent). A download's own add-ons start as its `addons/bundled.json`
says (the Cinematic camera and shaders, Immersive Weather, Immersive Enemies and Terrain Elevation on); `--addons` ones are always on. On
the first start with this rule, a settings file an earlier Zenith wrote keeps every add-on found then
on, as it was (saved as on, once; `[meta] addons_off_by_default` marks it done, and a fresh settings
file starts with it, so nothing found later is turned on that way). `--addons-default=on` brings back
the old rule: an add-on nobody switched is on.

## VR (experimental)

The client can draw the game in a VR headset through OpenXR: SteamVR (Index, Vive, Quest over
Link), Meta Quest Link or Air Link, Windows Mixed Reality. It runs on the PC next to Factorio (the
bridge is localhost-only), so a standalone headset streams from the PC. Start the headset's
runtime, then:

    godot --path client --xr-mode on -- --vr --factorio-port=34200               # tabletop
    godot --path client --xr-mode on -- --vr=first-person --factorio-port=34200  # first person
    ... --vr --vr-hand=left                                                      # left-handed

(`--factorio-port` connects at once; the menu is only on the desktop window. Without
`--xr-mode on`, or without a headset, `--vr` only prints a warning and the game runs as usual.)

**Tabletop** (the default) works like a map editor: the factory is a model on a table at waist
height in front of you. Grab it with a grip and drag it around; grab with both grips to move,
zoom (pull your hands apart or together) and turn it in one go. The chunks and live data (belts,
trains, robots) follow the table's centre, so you can look over the whole base while your
character stays where it is; clicking the other stick puts the table back on your character at
your height. **First person:** you stand where your character stands, a tile to a metre.

| | Pointer hand (right; `--vr-hand=left` swaps) | Other hand |
|---|---|---|
| Trigger | Left click: build, open, select (hold to drag-build) | Shift, while held |
| A / X | Right click: mine, cancel (hold to keep mining) | Character screen (E) |
| B / Y | Rotate (R) | Show the HUD panel in front of you, or hide it |
| Stick | Tabletop: turn the table 45° (left/right), zoom (up/down). First person: turn 30°. On the panel: scroll | Walk, the way you look |
| Stick press | Pipette (Q) | Tabletop: the table back on your character |
| Grip | Grab the table | Grab the table (both grips: move, zoom, turn) |
| Menu | | Esc |

The laser from the pointer hand is the mouse: where it meets the ground is where you build and
mine, and on the HUD panel (Factorio's windows, quickbar, minimap) it clicks like the mouse. The
desktop keyboard keeps working.

Not done yet: the main menu and the in-game Esc menu stay on the desktop window, Alt-mode labels
aren't placed on the panel, first person has no movement prediction (you feel the bridge's
delay) and no comfort options (vignette, smooth turn). Nothing of this has been tried in a
headset yet.

## Sky and clouds

Each planet has its own sky (`client/scripts/world/sky.gd`): a gradient with the sun, stars at night
and clouds, following the game's time of day. Clouds use Factorio's own cloud noise from the
install (`core/graphics/clouds-noise.png`, a generated noise without one) and cast soft shadows
that drift over the ground, as Factorio's do on Nauvis, Gleba and Fulgora (opacity 0.25, from the
planets' `surface_render_parameters`). Vulcanus and Gleba have a coloured haze (Factorio's fog),
Aquilo a cold one; Fulgora's nights have lightning flashes. Settings → Graphics → Clouds turns
clouds, shadows and haze off (`[graphics] clouds=false`); `--clean-shot` and `--review-shots` do too.
`--sky=<planet>[@<daytime>]` shows another planet's sky and holds the time of day (0 noon, 0.5
midnight), for screenshots against the mock: `--sky=fulgora@0.45`.

The planet seen from a space platform (`shaders/space_sky.gdshader`, main.gd `PLANET_CLOUDS`) layers its clouds with Factorio's own cloud, cloud-flow and cloud-normal maps from the install (`space-age/graphics/space/<planet>-cloud*.png`, read at run time): the clouds' own colour and alpha, a slow flow along Factorio's flow map (`planet_spin.gd` `cloud_flow()`, game ticks), relief and a soft warm terminator, a shadow on the ground, edges broken up by noise on the sphere (no seam or pole pinch), thinner at the limb and an atmosphere rim on the lit side, tuned per planet; `--planet-clouds=old` draws them as before (luminance as alpha, no flow, relief or shadow).

Two full-screen passes are drawn only when they can show something (0.2.1): the cloud shadows' (and
haze's) pass is hidden while it would draw nothing, at night on a planet without haze; and the smog's
(Settings → Graphics → Smog, `scripts/world/pollution.gd`) only while a chunk it can read for the
camera holds smog: the chunks between the camera and where the screen's corners meet the ground,
and two round them (with the horizon in view, any chunk the bridge has). Volumetric smog lifts from
low industrial haze into rising convective plumes and a blurred aloft smog canopy (`128 × 128` chunks),
retaining distant pollution across moving `pol` windows, charted `map_pollution`, and `pols` sweeps with
a per-surface RAM and `user://pollution-cache/` Zstd disk cache, pre-baked seamless billow noise, and
a cheaper far-horizon band out to 1,600 tiles (`--smog-look=old` keeps the earlier flat 5-tile layer;
`--smog-cache=off` restores wiping distant pollution outside the latest `pol` square and disables disk caching).

Settings → Graphics → **God rays** (`[graphics] god_rays`, `scripts/world/god_rays.gd`, default `0.5`)
draws volumetric sun shafts up to 640 tiles through gaps in the active cloud layer (Zenith's built-in
clouds or a look's `cloud_field` such as Cinematic Shaders), trees, buildings, rising plumes and aloft
smog; it is hidden with zero GPU cost when set to Off (`0%`), in deep night, on space platforms, or with
`--god-rays=off|<0..1>` / `--clean-shot`.

## Additional Client Flags (from Troubleshooting)

Full context in [PROFILING-NOTES.md](PROFILING-NOTES.md) and [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

### Flags A–D

- --aa-probe-shots: `--aa-probe-shots` (with `--ao-probe=`) saves the window under each anti-aliasing choice in turn
- --all: - `tools/check.py`: `art-src/check-logs/<check>.godot.log` in the main checkout (`--all --logs <folder>`: there);
- --alt-flat-batch: ...picking instead of node-backed movers; `--alt-flat-batch=off` interleaves each quality mark after its icon in `_flat` Alt-mode instead of drawing icons before t...
- --alt-native: - `--alt-native=off`: Alt-mode's icon instances on the card sorted farthest first, packed and joined in GDScript (`_gpu_fill`, `_gpu_sort_chunks`), a turned view refilling every chunk within the 1.5 ms budget as before; on (the default, when the native library is loaded) `AltIconsNative` (`client/native/belt_sim/src/alt_icons_native.cpp`) holds each chunk's icons and sorts them, the same buffer byte for byte (`alt_overlay.gd`).
- --alt-incremental: - `--alt-incremental=off`: Alt-mode's chest contents, machine rows (modules, packs, ammo, cargo) and fluid icons rebuilt for the whole map whenever any chunk, `ac`, `am`, `aiu` or `fl` changes, as before; on (the default) only the chunks that changed are built again, in view the same frame (capped at 3 ms of chunks a frame), the rest within the card path's 1.5 ms budget (`alt_overlay.gd`).
- --alt-relift: - `--alt-relift=off`: with `--alt-incremental`, a change of the ground's heights (an add-on's hills, each step of a fade) builds every chunk's Alt-mode icons again entity by entity, as before; on (the default) the icons already worked out are lifted onto the new ground where they are looked at (`AltIconsNative.lift` in C++ when the library has it, else GDScript), a chunk whose icons did not move costing no hash and no upload, and the card path keeps each cache's pictures' layers (`alt_overlay.gd`).
- --alt-quiet-builds: - `--alt-quiet-builds=off`: with `--alt-incremental`, every `entities_changed` world.gd sends after building a chunk again (a model loaded, a LOD's MultiMeshes) marks the chunk's Alt-mode icons to be built again and asks a redraw, and every change looks at every chunk's stamps, as before; on (the default) a loaded chunk whose records are the ones its icons were built from is left alone, and the card path's stamp check runs in one pass over the loaded chunks only when the chunks' or records' counts or an "all" key changed (`alt_overlay.gd`).
- --alt-icons-later: - `--alt-icons-later=off`: an Alt-mode icon not yet read (Alt-mode turned on over a part of the base never seen, a new kind in a chest) is read and composed on the main thread as its chunk's icons are built, and the card's texture array starts at 32 layers, as before; on (the default) it is read on a worker thread (`Kit.icon_request`, the hover panel's `--icons-later` jobs) while the chunk is built without it, the chunk built again once it is in the caches, and the array starts at 256 layers (`alt_overlay.gd`).
- --alt-marks-sliced: - `--alt-marks-sliced=off`: Alt-mode's arrows (`alt_arrows.gd`) and quality marks (`quality_marks.gd`) work out every changed chunk in the frame Alt-mode comes ...
- --analyze: started or reused, and how the recorder sampled (with `--analyze`, from status.txt, settings.cfg and
- --anim-hud: (`--anim-hud` keeps the HUD), with `--anim-pose=<run|mine|aim|...>` holding the character in one
- --anim-pose: (`--anim-hud` keeps the HUD), with `--anim-pose=<run|mine|aim|...>` holding the character in one
- --anim-rate: take-off, hovering and landing every 4 s), `--anim-rate=<x>` playing it at x times its speed (0.1
- --anim-shots: `--anim-shots=<dir>@<start>,<count>,<step>` saves `count` frames `step` seconds apart
- --anim-sweep: `--anim-sweep=old` forgets the animator's states of entities gone all in one frame every 5 s, as before (`anim.gd`); by default the pass is spread over frames, about 0.2 ms each.
- --ao-probe: - `--ao-probe=<out.txt>[@seconds]`: after 20 s (or the seconds given) lists every model MultiMesh
- --ao-probe-ab: `--ao-probe-ab=<bias>,<normal bias>` saves the window before and after setting the
- --ao-probe-bias: sun's shadow biases (`<out>-a.png`, `<out>-b.png`), `--ao-probe-bias=` holds them there, and
- --ao-probe-own-shadows: `--ao-probe-own-shadows` makes every model cast its own shadow with the stand-ins hidden.
- --ao-probe-shots: SSAO and ao_zoom.gd's reading. It doesn't quit, except with `--ao-probe-shots`: then it saves the
- --armor: every worm folded, up or attacking. The mock's `--fly loop|walk` (with `--armor mech-armor`) makes
- --at: --worktree <checkout> --ports <udp>,<game>,<rcon> [--at x,y] [--size 64] [--seconds 10] [--settle 40]
- --atomic-chunk-reveal: - `--atomic-chunk-reveal=off`: show chunk terrain immediately when meshed rather than holding ground visibility (`REVEAL_HOLD_MSEC = 600` timeout) until initial...
- --background: ...cliffs are unchanged. Rebuild: `blender --background --factory-startup --python tools/models/nature/build_nature.py -- <names>`, then `tools/models/part_colors....
- --baked-anim: says (the burner drill's counterweight arm sat 7 cm off). `--baked-anim=old`: 30 frames a second, at most 512,
- --belt-capture: - `--belt-capture-thread=on`: `--belt-capture` writes each `bs` message on a thread of its own, which
- --belt-capture-thread: - `--belt-capture-thread=on`: `--belt-capture` writes each `bs` message on a thread of its own, which
- --belt-draw-coalesce: - `--belt-draw-coalesce=off`: every change the simulation emitted in a job's ticks is made into a record,
- --belt-draw-dump-parks: - `--belt-draw-dump-parks=off`: the draw dump leaves out a parked item's record going (`--belt-draw-view`: an
- --belt-draw-early: 24 ticks or the command line's N), Rescue seen (`--belt-sim-rescue-seen`), Early changes (`--belt-draw-early`),
- --belt-draw-early-stop: (`--belt-draw-early-stop`), Longer lead (`--belt-sim-ahead=auto` with `--belt-draw-lead-lag`; off: a fixed lead,
- --belt-draw-edge-shut: (`--belt-draw-handover`), Shut edge ends (`--belt-draw-edge-shut`) and Items keep their turn (`--belt-draw-turn-id`;
- --belt-draw-gone-order: - `--belt-draw-gone-order=off`: a job applies every change, then removes every item gone in its ticks (an
- --belt-draw-handover: (`--belt-draw-handover`), Shut edge ends (`--belt-draw-edge-shut`) and Items keep their turn (`--belt-draw-turn-id`;
- --belt-draw-head-move: - `--belt-draw-head-move=off`: the simulation's changes say the step a head item was given (items
- --belt-draw-later-tick: `--belt-draw-later-tick`), `early_tries` and `early` (early tries and takes, summed), `drained` (items whose
- --belt-draw-lattice: - `--belt-draw-lattice=off`: every lane drawn from the simulation, as before. On (the default): a lane
- --belt-draw-lattice-close: - `--belt-draw-lattice-close=off`: as before, the lanes behind a take's hole in a standing lane stood while the
- --belt-draw-lattice-creep: - `--belt-draw-lattice-creep=on` (off by default: as before, a standing lattice lane moves only when the simulation's front
- --belt-draw-lattice-mask: - `--belt-draw-lattice-mask=ends`: as before, a lattice lane marks the mask's cells along its centre line from end
- --belt-draw-lattice-native: - `--belt-draw-lattice-native=off`: the lattice made in GDScript (`belt_lattice.gd`), as before. On (the
- --belt-draw-lattice-open: Take past the edge (`--belt-sim-take-edge`), Open lattice ends (`--belt-draw-lattice-open`), Clean handover
- --belt-draw-lattice-pile: - `--belt-draw-lattice-pile=off`: every lattice slot one item, whatever the lane's stacks (the lattice's
- --belt-draw-lattice-settle: - `--belt-draw-lattice-settle=off`: as before, a standing lattice took its lane's new speed at once. A take
- --belt-draw-lattice-sim-full: - `--belt-draw-lattice-sim-full=off`: as before, a moving lane stays a lattice while the bridge's last read or
- --belt-draw-lattice-start: - `--belt-draw-lattice-start=off`: as before, with settle a standing lane takes a new speed only once the
- --belt-draw-lattice-tail: - `--belt-draw-lattice-tail=off`: as before, a moving lane a packed block had filled stayed a lattice after the
- --belt-draw-lattice-turns: With per-item turns (`--belt-draw-lattice-turns`) a lane that starts or stops keeps each item's turn;
- --belt-draw-lattice-unison: - `--belt-draw-lattice-unison=off`: the lattice as first built: a slice of the drawn lanes has its speed
- --belt-draw-lead: - `--belt-draw-lead=off`: a record that ends is made again only once it has ended (the item stands at
- --belt-draw-lead-lag: (`--belt-draw-early-stop`), Longer lead (`--belt-sim-ahead=auto` with `--belt-draw-lead-lag`; off: a fixed lead,
- --belt-draw-lead-max: - `--belt-draw-lead-max=N` (32): the most ticks a job's lead is (how far ahead a record that ends is made again, and
- --belt-draw-margin: - `--belt-draw-margin=N` (120): the most ticks the drawn clock is held behind the game's clock for the
- --belt-draw-native: - `--belt-draw-native=off`: a job's records are planned and written in GDScript, as before. On (the
- --belt-draw-park-lattice: - `--belt-draw-park-lattice=on`: an item whose motion lies on lanes the lattice draws all along (its place and
- --belt-draw-pile: - `--belt-draw-pile=off`: each copy of a pile (a stack on a belt, up to four in one place) gets a full
- --belt-draw-skip-same: - `--belt-draw-skip-same=off`: every job is given a fresh copy of the kinds' looks and a fresh list of the far
- --belt-draw-small-pages: - `--belt-draw-small-pages=off`: the records' pages (`f3d_belt_records`, `f3d_belt_lattice`) are 16 rows of
- --belt-draw-turn-id: (`--belt-draw-handover`), Shut edge ends (`--belt-draw-edge-shut`) and Items keep their turn (`--belt-draw-turn-id`;
- --belt-draw-view: - `--belt-draw-view=off`: every item gets a record wherever it is, as before. On (the default): an item
- --belt-draw-view-ground: - `--belt-draw-view-ground=off`: the camera's ground view for `--belt-draw-view` is cut 160 tiles along
- --belt-draw-view-lead: - `--belt-draw-view-lead=on`: the job's view is stretched ahead of the camera's own motion, as far as it goes in
- --belt-early-bs: - `--belt-early-bs=off`: `bs` parts that come before the world is ready (the bridge's welcome done, the
- --belt-item-contact: a frame on the CPU; a pile's copies and inserters' hands have none. `--belt-item-contact=off`: no box (as
- --belt-items-sync: `--probe-render-times` (each read waits for that thread). `--belt-items-sync` handles belt items on
- --belt-job: - `--belt-job=pool`: belt items' jobs go back to Godot's worker pool (`--belt-job-high=off` chooses low priority)
- --belt-job-high: - `--belt-job-high=off`: belt items' job goes to Godot's worker pool as a low-priority task, as before.
- --belt-lane-vcull: ...ring retention (`0..12`, default `4`); `--belt-lane-vcull=off` skips vertex-stage lane distance culling; `--tree-shadow-decimate=off` keeps all non-core leaf ca...
- --belt-lanes-dump: - `--belt-lanes-dump=<file>` (a diagnostic): the lane icons as made and dropped, the icon shader's square
- --belt-lanes-start-sliced: - `--belt-lanes-start-sliced=off`: belt lanes' job takes every waiting chunk (each chunk's curved belts read on the main thread), as before. On (default): what ...
- --belt-lods-every-frame: ...chunk belt checks under `FrameBudget`. `--belt-lods-every-frame` checks every transform change; `--belt-lods-slice=off` runs unbudgeted full-world single-frame ...
- --belt-lods-slice: ...-frame` checks every transform change; `--belt-lods-slice=off` runs unbudgeted full-world single-frame `BeltLods` checks.
- --belt-mask-tiled: - `--belt-mask-tiled=off`: upload all 16 layers of the `f3d_belt_mask` `Texture2DArray` whenever the lattice mask
- --belt-messages-first: - `--belt-messages-first=on|off` (on): the belt simulation's updates (`bs`) are handed to the belt layer as they are
- --belt-mid-lod: `--belt-mid-lod=off` disables the 3D mid-detail belt LOD tier (`belt_lods.gd`, `chunk_view.gd`), restoring the 2-tier Full/Flat switch.
- --belt-mv-change-flag: `--belt-mv-change-flag=off` makes `belt_mv.gd` and `item_cards.gd put_mv` hash every emitted motion-vector buffer again (`hash(buf)` twice a kind a frame) to find unchanged ones, instead of the native evaluator's per-kind change flag (`BeltMvNative` compares each slot as it writes it).
- --belt-mv-native-put: `--belt-mv-native-put=off` hands every changed belt motion-vector buffer back to GDScript (`belt_mv.gd _emit_put_mv`, `item_cards.gd put_mv`) as before, instead of `BeltMvNative.step` giving a kind whose last put went through `BeltItemsNative`'s fast path with the same count, size and bounds straight to that fast path (and skipping it when unchanged) itself.
- --belt-mv-page-dirty: `--belt-mv-page-dirty=off` makes a record page update re-evaluate every slot of each belt motion-vector kind whose records it touches, as before, instead of only the slots reading a touched page (their own record, or a pile copy's item record) plus the moving ones (`BeltMvNative`).
- --belt-mv-partial: `--belt-mv-partial=off` disables `belt_mv.gd` unchanged/off-screen batch upload skipping and restores unconditional `put_mv`/`restore_kind` syncs.
- --belt-mv-threads: `--belt-mv-threads=off` makes the native belt motion-vector evaluator (`BeltMvNative.step`) evaluate its kinds one after another on the main thread, as before, instead of one task a kind on the engine's worker pool (used when at least 2 kinds and 4,096 slots are due, and only on a worker pool of 3 threads or more: on a smaller one, `Settings.worker_threads_cap()` on 3 cores or fewer or `--worker-threads=1|2`, it is off by itself, since the waiting main thread does no task itself).
- --belt-mv-tight-cap: `--belt-mv-tight-cap=off` sizes each belt motion-vector MultiMesh buffer to its records' capacity, as before, instead of to its items (a quarter more, in steps of 256, grown at once and shrunk after 120 steps a quarter too big; `BeltMvNative`): fewer bytes sent to the renderer each frame, but a kind that changes size draws one frame without motion vectors.
- --belt-native-decode: - `--belt-native-decode=off`: decode `bs` message body lists (`sl`, `sh`, `ew`, `pc`, `pu`, `of`) in GDScript instead
- --belt-path-probe: `-- --belt-path-probe=drawn.json@20` (records 20 s after 10 s, prints belt items' main-thread and worker
- --belt-return-first: blended surface draws its top run last; `--belt-return-first=off` puts them after, as before.
- --belt-sim-ahead: (`--belt-draw-early-stop`), Longer lead (`--belt-sim-ahead=auto` with `--belt-draw-lead-lag`; off: a fixed lead,
- --belt-sim-ask: - `--belt-sim-ask=view` (the default): lanes asked for again (`bre`) by what shows: a lane the lattice draws only
- --belt-sim-ask-near: - `--belt-sim-ask-near=off`: a job's asks in the simulation's order. On (the default): nearest the middle of
- --belt-sim-ask-unknown: - `--belt-sim-ask-unknown=off`: a lane read (`sl`) or checked (`pc`) whose meta never came is left out, as
- --belt-sim-dead-walls: - `--belt-sim-dead-walls=on` (off by default: as before): a lane that leads nowhere in the simulation (no next by
- --belt-sim-hold: - `--belt-sim-hold=off`: the bridge's `sh` ignored. On (the default): a splitter's input the bridge found as
- --belt-sim-lattice-no-bre: - `--belt-sim-lattice-no-bre=off`: a lane the lattice draws (full of one kind) whose drift check (`pc`) fails
- --belt-sim-read-apply: - `--belt-sim-read-apply=off`: reads applied as before this round. On (the default): a lane's meta
- --belt-sim-read-conserve: - `--belt-sim-read-conserve=off`: reads drop what they don't have as before. On (the default): a read
- --belt-sim-read-forward: - `--belt-sim-read-forward=off`: the items a read leaves past its line's front (the read lane is the line's
- --belt-sim-read-skip-same: - `--belt-sim-read-skip-same=off`: a read (`sl`) that finds the lane exactly as the simulation has it (every
- --belt-sim-removed-now: - `--belt-sim-removed-now=off`: a belt Zenith takes away keeps its lanes and items until the bridge's `dl`, as
- --belt-sim-replace-at: - `--belt-sim-replace-at=off`: a lane the bridge drops (`dl`) goes the moment its update comes, as before. On (the
- --belt-sim-rescue-seen: 24 ticks or the command line's N), Rescue seen (`--belt-sim-rescue-seen`), Early changes (`--belt-draw-early`),
- --belt-sim-shift-keep: - `--belt-sim-shift-keep=off`: a read's packed-run shift goes on past an item outside the lane that the
- --belt-sim-split-reconcile: - `--belt-sim-split-reconcile=off`: a read (`sl`) of a splitter's input or output lane is applied as any other.
- --belt-sim-split-wake: - `--belt-sim-split-wake=off`: splitters let an item through whenever the belt rules say. On (the default):
- --belt-sim-take-edge: Take past the edge (`--belt-sim-take-edge`), Open lattice ends (`--belt-draw-lattice-open`), Clean handover
- --belt-sim-take-first: and BeltSimNative alike. Nothing is saved. Left out, as they need a restart: `--belt-sim-take-first` and
- --belt-sim-take-line: `--belt-sim-take-line` (the simulation queues takes and reads for them, left waiting if flipped), the lattice and
- --belt-sim-ug-guard: - `--belt-sim-ug-guard=off`: an underground's hidden tunnel lane the bridge sends no next for (`lm` next 0: an
- --belt-surface-blend: over the top ("chevrons pointing both ways"). `--belt-surface-blend=on` keeps it blended, as before
- --belts: lane reads: `--belts 40 --queue 36 --take 25 --feed 6 --ticks 2400 --hands-radius 4`, replayed with
- --bench: [rec.json] [--bench] [--tile=N]` starts from the recording's first tick, steps on by itself given only what
- --binary: the client runs them (`--binary`: each part written as a binary frame and read back first, as from a bridge
- --binary-messages: - `--binary-messages=off`: the hello leaves `bin` out and the bridge sends everything as JSON text, as before.
- --blend-clip: everywhere) stays blended, and built-in packs are unchanged. `--blend-clip=off` keeps it blended.
- --bridge: server/data/script-output/f3d-ih-trace.jsonl, off by default) `python tools/inserter_check.py --bridge
- --bs: --bs --capture` instead of Zenith (no Godot, no screenshots: for bridge-only runs; `--stand-in-cap`,
- --budget-floor-cap: `--budget-floor-cap=off` restores uncapped stacking of non-`messages` `FrameBudget` floors instead of capping them at 3500 us while reserving at least 1500 us for `REDUCERS`.
- --budget-hard-cap: - `--budget-hard-cap=off`: restore legacy unbounded `FrameBudget` floor stacking across low-priority systems once total work hits the frame ceiling.
- --budget-predict: - `--budget-predict=off`: sliced systems check only the clock between items. On (default): messages (by type), far belt icons (`lanes`), Distant Horizon section...
- --budget-spent: - `--budget-spent=off`: grants ignore the frame's other (unbudgeted) scripts' time already spent this frame. On (default): what they spent past their usual shar...
- --build-apply-deadline: - `--build-apply-deadline=off`: a chunk's build fills all its MultiMeshes in one go once its records
- --build-parts: - `--build-parts=each`: a chunk is built again on each `ents` part of its snapshot, as before. On:
- --queue-order: `--queue-order=old`: the build queues (pending, part-way, live and dirty chunks, finished prep jobs) sorted with `sort_custom(nearer)` and the terrain jobs by `[rank, coord]` arrays, as before. On (default): one packed key a chunk (`(live?0:1)<<62 | rank<<20 | index`) sorted natively, the same order but ties by place; dirty chunks that would only be passed over (building, prep job queued, snapshot still coming, replaying) left out before ranking.
- --build-rec-cache: ...ol` for chunks with `>= 48` instances. `--build-rec-cache=off` and `--chunk-mm-worker=off` restore uncached main-thread builds.
- --burner-fx: - `--burner-fx=on|off` (on): while a burner inserter whose model has a glowing burner (Vasillo's; the built-in
- --burner-scan: - `--burner-scan=old`: the burner inserters' wisps and crackle (`burner_fx.gd` `scan`, four times a second from `fx.gd` `_scan`) look at every moving inserter hand loaded, as before. On (default): only the inserters of the chunks within 30 tiles of the listener (a per-chunk list kept from the world's `entities_changed`); the same burners burn (perf-world-8, `client/tests/fluids_burner_scan_test.gd`).
- --cam: `--cap=N` for an Items in 3D cap of N, and `--cam=x,z` for a drifting camera leading it, so both paths'
- --camera-cone: ...fault** (it has not been run in play): `--camera-cone=on` tries it; its chunk boxes grow with Terrain Elevation's hills (`GroundHeight.lift_range()`) and it sen...
- --cap: `--cap=N` for an Items in 3D cap of N, and `--cam=x,z` for a drifting camera leading it, so both paths'
- --capture: --bs --capture` instead of Zenith (no Godot, no screenshots: for bridge-only runs; `--stand-in-cap`,
- --char-lod-zoom: ...s.gd`, `far_chunks.gd`, `ao_zoom.gd`): `--char-lod-zoom=off` restores fixed character-anchored LOD, belt stand-in, far-chunk merge, and SSAO distances that igno...
- --chunk-disk-cache: - `--chunk-disk-cache=off` / `--chunk-disk-cache-mb=<N>` (Settings > Graphics `"chunk_disk_cache"`, default on / `512 MB`): disable or cap the persistent Zstd 1...
- --chunk-disk-cache-async: - `--chunk-disk-cache-async=off`: restore legacy main-thread disk-cache JSON stringification and region encoding instead of background `WorkerThreadPool` encodi...
- --chunk-disk-cache-mb: - `--chunk-disk-cache=off` / `--chunk-disk-cache-mb=<N>` (Settings > Graphics `"chunk_disk_cache"`, default on / `512 MB`): disable or cap the persistent Zstd 1...
- --chunk-mm-worker: ...instances. `--build-rec-cache=off` and `--chunk-mm-worker=off` restore uncached main-thread builds.
- --client-arg: running after writing the file, so `tools/belt_view_check.py --client-arg=--stutter-probe=<out>@join
- --client-setting: ...draw-dump on|off] [--client-arg=<arg>] [--client-setting=<key>=<value>]`. It starts that checkout's server on a copy of its `server/saves/zt.zip`
- --cliff-fit: ...at ground or no cliff near: as before. `--cliff-fit=off`: the rock on the low ground at its own height and the blocks on the terraced ground, as before. Terrain...
- --cliff-ground-normal: ...ves' and the distant horizon's levels. `--cliff-ground-normal=old`: as before. Terrain Elevation 0.1.8 fixes the field's own groove there (*Step follows the roc...
- --cliff-ground-tint: ...player's floor or the shore's shelves. `--cliff-ground-tint=off`: no tint. The tint is ragged scree (patches with a broken edge, colours between `#61492f` and t...
- --cliff-low-shadow: ... foot (cliffs near black in daylight). `--cliff-low-shadow=old` lifts them by the terraced ground as before.
- --cliff-pieces: ... at its cell's edge, so any joins any. `--cliff-pieces=old` draws the first pieces (separate columns on a ridge, kept as `cliff-<piece>-old.glb`, never picked a...
- --cliff-scree-look: ...492f` and the wall's apron `#7a6040`); `--cliff-scree-look=old`: the even band as before. Terrain Elevation 0.1.7 gives the channel (its setting *Bare ground by...
- --cliff-wall: ...all** (`cliff_wall.gd`; on by default; `--cliff-wall=off` or Settings → Graphics → *Cliffs as one wall* off gives the pack's pieces, `--cliff-wall=on` forces th...
- --cloud-ray-opt: `--cloud-ray-opt=off` restores fixed volumetric cloud empty-space raymarch stepping and unconditionally samples 3D detail fetches in `cinematic_grade.gdshader`.
- --coalesce-updates: - `--coalesce-updates=off`: disables live fast-lane routing (`_live_waiting`: `ie` when `_chunk_waiting` is empty, plus
- --collect-cache: `--collect-cache=off`: every chunk build walks its records and the far merge's gather reads them one by one, as before (on: a build kept for the view alone and the far gather read the lists the last build kept; [Chunk streaming](#chunk-streaming-the-views-direction-the-area-cache)).
- --confirm-emu: recorded splitter input whose items at an update are its last read's), `--confirm-emu=split|all` reads such
- --contact-inner: `--contact-inner=hard`: as before.
- --contact-patch: drill has none past its body. `--contact-patch=wide`: as before.
- --contact-rim: `--contact-rim=clamped`: one clamped ring a foot, as the drill-border fix first had it.
- --contact-shape: time (about 13 ms each, a third of their load), 2.9 MB of atlas. `--contact-shape=box`: the rings for all, as
- --cut-lods: - `--cut-lods=old`: levels of detail catch up over frames after a camera cut, as before. On (default, `view_ahead.gd`): a viewpoint announced ahead (`api.world.prepare_view`, the Cinematic camera's keyed shots a second before each `"cut": true` key) has its chunks' model levels, far merges and cliff wall levels picked for it under the usual budgets before the camera gets there, and a cut seen (the camera moving more than 32 tiles in one frame, or `api.world.mark_cut`) picks every chunk's levels and far merges in that frame without the frame budget, the 16-switch cap or cross-fades (the Distant Horizon's near-edge fades end and its sections are looked at next frame). Also while announced: behind-the-camera culling keeps the chunks within 3 of the viewpoint drawn (so the Distant Horizon has stepped aside there); at a cut it shows chunks and sends their visibility unsliced, and the chunks within 2 of the camera add their MultiMeshes left for later at once. A chunk come near whose merged far mesh hides nothing (cliffs alone, drawn by the cliff wall) drops that mesh; with `old` it stood, the wall hidden behind it.
- --cut-shots: - `--cut-shots=<folder>`: a check: saves the first frame drawn after each camera cut and the one 30 frames on (`cut-NN-first|later-new|old.png`) and logs each cut's settle cost and the chunks round the camera (merged, wall levels, Distant Horizon cover), plus each announced viewpoint.
- --decode-thread: - `--decode-thread=off`: map charts' pictures (`chart`) and chunks' tiles (`chunk`) are decoded on the
- --decor-composite: `--decor-composite=off` draws every `FlatSheet` as before (also with `--grass-opt=old`, `--grass-backlight=old` and
- --decor-nodes: - `--decor-nodes=<n>`: at most about n new decorative MultiMeshes put in a frame, a whole chunk at a time, the first chunk of a frame always (default 96; `0` no...
- --decor-parallel-load: - `--decor-parallel-load=off`: holds `_kind_mutex` across decorative picture loading (one worker at a
- --decor-sheet: - `--decor-sheet=off`: keeps flat decoratives as separate per-kind MultiMeshInstance3Ds per chunk instead of baking them into one chunk sheet (`decor_sheet_bake...
- --decor-sheet-compress: - `--decor-sheet-compress=on`: S3TC block-compresses baked decorative chunk sheets in editor builds (off by default to avoid `Image.compress` stalling `WorkerTh...
- --decor-texture-thread: - `--decor-texture-thread=on` (the default; off as before): a decorative's atlas goes on the GPU on the
- --dh-async-io: ...hold, and unload-takeover holding, and `--dh-async-io=off` restores legacy sync `LodCache` region reads and main-thread region encoding. `--distant-horizon=off|...
- --dh-handoff: ...r cross-fade at the loaded-chunk seam, `--dh-handoff=off` disables load-underneath mask grace frames, extended DH reveal hold, and unload-takeover holding, and ...
- --dh-map: `--dh-map=old` keeps one entry a chunk. Region caches live in `user://lod-cache/` (`Zstd`, 256 MB LRU), and `user://pollution-cache/` (`Zstd`, disabled by `--sm...
- --dh-palette: `--dh-palette=old` rebuilds it on the main thread, draws every section again and scans and sorts every
- --dh-retire-index: `--dh-retire-index=off`: every retiring Distant Horizon node (a section's old mesh kept until the sections over it are built) scans all sections every frame for one still building, and `has_mesh_for_chunk` walks every retiring node (`distant_horizon.gd` `_gc_retiring`), as before. On (default): a retiring node looks up only the sections over its rect by key, the one that blocked it last first, and only after something could free it (a mesh installed, the layout re-centred, `finish_all`, a reset); retiring nodes indexed by section key; same nodes freed, `tests/dh_sections_test.gd` (perf-w4-dh).
- --dh-sample-worker: - `--dh-sample-worker=off`: Distant Horizon samples each section's grid from its chunks (the majority tile and the top entity a cell) on the main thread before its mesh job starts (`distant_horizon.gd` `_sample_section_grid`), as before. On (default): the main thread only gathers the section's chunk rows (`_gather_section_rows`) and the mesh job samples them on its worker first (`lod_mesher.gd` `sample_grid`); the same grid, `tests/dh_sample_worker_test.gd` (perf-w3-bridge).
- --dh-seam-fade: ...turns off the character-anchored LODs. `--dh-seam-fade=off` disables smooth 0.30s Bayer cross-fade at the loaded-chunk seam, `--dh-handoff=off` disables load-un...
- --dh-sub-scan: `--dh-sub-scan=old`: the chunk-request scan (`_collect_want_batch`) looks up the disk cache and charted map per chunk and checks its 4 ms budget only between sections, as before. New (default): cache checks hoisted out of the chunk loop, each pending cache region looked up once a call, the charted row fetched once a chunk row, and a 1.5 ms budget checked every block row with the section's place kept to resume next time (the next call of that kind starts at the section it stopped at and goes round, so sections past the budget get their turn); same requests and flags once drained, `tests/dh_sections_test.gd` (perf-w4-dh).
- --dh-vis-incremental: `--dh-vis-incremental=off`: each time a chunk loads, unloads or finishes fading, or a section gets a mesh, Distant Horizon looks at every section to hide the level-0 ones under loaded chunks (`distant_horizon.gd` `_update_lod0_visibility`), as before. On (default): only the level-0 sections of those chunks (and the one that got a mesh) are looked at; a re-centre, a reset or all fades ending still look at all of them; same `visible`, `tests/dh_sections_test.gd` (perf-w4-dh).
- --disk-flush-sliced: - `--disk-flush-sliced=off`: the chunk disk cache's flush (every 10 s) copies every dirty region's chunks (up to 256 a region) in the frame it starts, as before...
- --disk-flush-fine: `--disk-flush-fine=off`: the sliced flush checks its clock every 8 chunks, copies each chunk's extras in one go and lets the copies go on the main thread when the write is done, as before. On (default): the clock after every chunk, a chunk's extras deep-copied 64 at a time (carried on next frame), the write task empties its snapshots itself; `--stutter-probe` parts `dc_snap` and `dc_free`.
- --disk-promote-sliced: - `--disk-promote-sliced=off`: a region read from the disk cache promotes all its waiting chunks into the memory cache in that frame, as before. On (default): 1...
- --distant-horizon: ...reads and main-thread region encoding. `--distant-horizon=off|<chunks>` (`16..512`) overrides the radius and `hello` `lod` opt-in; `--distant-horizon-quality=mi...
- --distant-horizon-detail-lod: ...nt-horizon-dropoff=near|balanced|far`, `--distant-horizon-detail-lod=off|on`, and `--lod-night-glow=off|on` tune DH directly. The colour table
- --distant-horizon-dropoff: ...uality=minimal|low|medium|high|ultra`, `--distant-horizon-dropoff=near|balanced|far`, `--distant-horizon-detail-lod=off|on`, and `--lod-night-glow=off|on` tune ...
- --distant-horizon-quality: ...s the radius and `hello` `lod` opt-in; `--distant-horizon-quality=minimal|low|medium|high|ultra`, `--distant-horizon-dropoff=near|balanced|far`, `--distant-hori...
- --double-buffer-refresh: - `--double-buffer-refresh=off`: clear existing chunk entities immediately on incoming `"chunk"` headers rather than staging multi-part `"ents"` snapshots and s...
- --draw-dump: [--record-bounds view|square] [--draw-dump on|off] [--client-arg=<arg>] [--client-setting=<key>=<value>]`. It starts that checkout's server on a copy of its `se...
- --drawn-check: --drawn-check --every-tick [toggles]` replays a capture (`--belt-capture=bs.jsonl`) with a job a tick as
- --drawn-explain: simulation has it, by cause (`--drawn-explain=N` examples, `--trace=UID` one item). Without a camera every
- --drill-wet: fluid), if the drill's pack has it; a chunk is drawn again when that bit changes. `--drill-wet=off`: never.

### Flags E–L

- --east: `--job-every=30`): going east (`--east`) 1.16% of the game's item-ticks undrawn against 0.76% (the join's cell
- --elevated-trains: ...l_layer`) stand at the track's height. `--elevated-trains=old`: as before (3 tiles, rails found by selection boxes, no pitch, signals on the ground).
- --emission-strict: (KHR_materials_emissive_strength). `--emission-strict=off` reads them as before 0.2.2.
- --events: --trace=<f3d-ih-trace.jsonl> [--events] [--lose=0.18]` the layer against a real trace, fed samples or
- --every: `--view=-4,4,52,13` and scored by `tools/belt_quirks.py --every 30`, draws stop-and-go lanes standing (E46).
- --factorio-locale: for that `rate` level from the start; `--factorio-locale=<code>` uses that language's names
- --factory-startup: ...changed. Rebuild: `blender --background --factory-startup --python tools/models/nature/build_nature.py -- <names>`, then `tools/models/part_colors.py <names>` a...
- --far-belt-3d-dist: ...`, `item_models.gd`, `belt_items.gd`): `--far-belt-3d-dist=<tiles|all>` (default `48` at Medium LOD quality, `all` renders LOD1 3D models to full `bfar` distanc...
- --far-belt-variants: ...D1 3D models to full `bfar` distance); `--far-belt-variants=on` (keeps multi-variant models on far chunks instead of 1); `--far-item-pbr=full` (keeps normal and...
- --far-coarse: ...e leaf cards in tree shadow stand-ins; `--far-coarse=off` disables the outer `0.8 m` coarse far-merge HLOD tier.
- --far-decide-runs: ... when panning. `--shadow-runs=off` and `--far-decide-runs=off` rescan all loaded chunks; `--far-prep-guard=off` skips cancelling in-flight merged worker `ChunkP...
- --far-installs: - `--far-installs=N`: at most N finished far-chunk merges put in a frame (default 1; `0` no cap, as before, within the frame budget's `far_install` slice).
- --far-item-pbr: ...nt models on far chunks instead of 1); `--far-item-pbr=full` (keeps normal and ORM texture fetches on far 3D belt items); `--lattice-variants=close|all|off` (de...
- --far-merge-cap: `--far-merge-cap=<tiles>` sets the cap, 0 none (as 0.2.0).
- --far-merge-from: `--far-merge-from=<tiles>` merges far chunks' buildings from that distance instead of about four
- --far-merge-sooner: - `--far-merge-sooner=<f>`: far chunks merge (and unpack) this many times sooner than before, by screen size or by distance from the character (default 1.3: the...
- --far-prep-guard: ...de-runs=off` rescan all loaded chunks; `--far-prep-guard=off` skips cancelling in-flight merged worker `ChunkPrepJob`s when a far chunk comes near.
- --far-priority: - `--far-priority=legacy`: keep uncovered `far_collect` / `far_install` merges at Priority 8 with a `0` frame-budget floor instead of promoting uncovered outer-...
- --far-trees: - `--far-trees=off`: keeps trees and plants as MultiMeshes in far chunks instead of merging their trunks and crowns.
- --fast-edit-rebuild: - `--fast-edit-rebuild=off`: disables live-edit rebuild priority (`_dirty_live` preemption ahead of background `_dirty`
- --fast-night-clouds: ...ng the uploaded camera focus distance; `--fast-night-clouds=off` keeps full 14-step cloud marching and solar lookups at deep night.
- --feed: lane reads: `--belts 40 --queue 36 --take 25 --feed 6 --ticks 2400 --hands-radius 4`, replayed with
- --feed-loose: Offline (`tools/belt_bursts.py --mode out --open 99999,99999 --shut 1,1 --feed --feed-loose 0.1 --tier yellow
- --first-bs: [--settle-max 180] [--first-bs 60] [--settings automatic|unlimited] [--hold60 on|off] [--record
- --fix-imports: ...ools/models/bake_pbr.py --names <names> --fix-imports`.
- --fluid-windows-index: - `--fluid-windows-index=off`: every complete `fl` draws the fluid windows again, walking every fluid box in view, as before. On (default): `fluids_power.gd` keeps the storage tanks and windowed straight pipes per chunk, draws again only when one of their first boxes' fluid, amount or capacity moved (or their chunk or the models changed), walks only those, and keeps each pipe's column placement until its chunk changes; the same windows (perf-world-8).
- --flicker-probe: - `--flicker-probe=<folder>[@degrees a frame]`: saves frames while the camera turns slowly;
- --fly: every worm folded, up or attacking. The mock's `--fly loop|walk` (with `--armor mech-armor`) makes
- --frame-budget: handed out by priority, with a floor for the near work. `-- --frame-budget=separate` gives every
- --frame-budget-belts: - `--frame-budget-belts=first|off` (first): the far belt icons' slice (belt_lanes.gd, `lanes`) ranks with the
- --frame-budget-measure: - `--frame-budget-measure=godot`: the frame budget's pool is worked out from Godot's
- --free-later: - `--free-later=off`: nodes and old meshes the world lets go of (a far chunk's merged mesh when it comes near or is merged again, a chunk's ground, decoratives,...
- --free-later-leaves: - `--free-later-leaves=off`: a node waiting in `free_later.gd` freed whole with its children in one `free()`, its meshes with it (frame-spikes2's way: one big c...
- --from-factorio: - `--from-factorio` is what server/factorio-with-zenith.ps1 passes when Ctrl+F9 in Factorio starts
- --fx-opt: `--fx-opt=off` restores legacy linear FX removal and uncached/uncapped smoke-trail updates in `sprite_fx.gd` and `weapon_fx.gd`.
- --fronts-trace: every 30 ticks seldom has the simulation's own ticks, which the plain dump needs); `--fronts-trace=K1,K2,...`
- --gate-by-id: `--gate-by-id on` makes it a gate again, under 90% failing), with the client's own pace (jobs with updates and their ms, updates
- --gate-model: ...he yellow to the stone wall's colour). `--gate-model=old` draws the model it had before (pale stripes, low rails), kept as `gate-old.glb`. Rebuild: `python tool...
- --gate-open: - `--gate-open=old`: (the guess, for gates without a real state) a gate's door opens while the
- --gate-state: - `--gate-state=guess`: a gate's doors guess from what is near whatever the bridge sends, with the fixed 4-tile
- --ghost-lod: ...d`, `model_lods.gd`, `far_chunks.gd`): `--ghost-lod=off` keeps full-detail meshes for far ghosts; `--warm-rings=<n>` sets warm ring retention (`0..12`, default ...
- --glide-probe: - `--glide-probe=<out.json>[@seconds]`: goes through the bridge's `rate` levels 0 to 3 (30 s each)
- --godot-arg: `--godot-arg=--gpu-profile` passes Godot its own flag so the probe also gets the render steps' times.
- --governor-apply: - `--governor-apply=held` (the default; `all` as before): a UPS governor step applies only the knobs it
- --governor-belts-last: - `--governor-belts-last=on|off` (on): Hold the game at 60 UPS cuts the belt item distance (`far` 96, 64, 32) only
- --gpu-profile: `--godot-arg=--gpu-profile` passes Godot its own flag so the probe also gets the render steps' times.
- --grade-focus-uniform: ...ooks.gd`, `cinematic_grade.gdshader`): `--grade-focus-uniform=off` samples depth per pixel in the grade shader instead of using the uploaded camera focus distan...
- --graphics-layout: - `--graphics-layout=old`: restores the previous single-column Graphics settings window (`General`,
- --grass-backlight: values (natural 1.0 / 0.15, floors 0.8 / 0.3), `--grass-backlight=old` the plants' (specular 0.5, carpet roughness
- --grass-opt: 0.20, were 0.45 / 0.35). `--grass-opt=old` draws the previous shaders (`decorative_*_old.gdshader`: blended tufts,
- --grass-zoom-lines: ...tives.gd`, `avatar.gd`, `ao_zoom.gd`): `--grass-zoom-lines=raw` uses unclipped viewport lines for 3D grass; `--lantern-shadow=cube` uses 6-face cube shadows ins...
- --ground-relief: every distance, `--ground-relief=on|off` forces them whatever the setting; the probe's `relief off`.
- --ground-rough: behind the scene paving glared pale and back-lit grass turned white. `--ground-rough=off` gives the ground 0.2.2's
- --ground-swap: ...thing is sent when no height changed). `--ground-swap=old`: the textures swapped as before.
- --ground-walk: - `--ground-walk=old`: when the hills' range grows (a new field from Terrain Elevation), the whole scene tree searched and every drawn node given room in that f...
- --groups: `--groups` to say `bg` too, `--runs` to say `br` (straight runs moved by the client). It warms up for
- --hands-radius: items unseen, phantoms). Its `--hands-radius R` sets the bridge's f3d-detail-radius so only the inserters within
- --headless: (`python tools/belt_sim/record.py`): `godot --headless --path client -s res://tests/belt_sim_replay.gd --
- --heat-glow: - `--heat-glow=heat|always` (heat): a heat pipe model's glow (FUE5's heat pipes' copper) follows its temperature,
- --heavy-lods: - `--heavy-lods=off`: old level thresholds for heavy building models. On (default): a model's levels switch in sooner (smaller on screen) by sqrt(triangles / 10...
- --hold-emu: the live client never got: -62,-26 replayed 91.9% visible with it, 87.5% without). `--hold-emu` makes the bridge's `sh` from the recording (a
- --hold60: [--settle-max 180] [--first-bs 60] [--settings automatic|unlimited] [--hold60 on|off] [--record
- --hover-highlight-cache: `--hover-highlight-cache=off` disables caching unchanged hover/build highlight state in `player_input.gd`.
- --hover-rate: - `--hover-rate=off`: the entity info panel (the hover panel) is rebuilt for every new entity under the cursor while the character runs too, as before. On (defa...
- --icons-later: - `--icons-later=off`: the entity info panel (the hover panel) reads an icon that isn't cached yet at once,
- --idle-dims-glow-paint: picture already didn't). `--idle-dims-glow-paint=on` dims it as before 0.2.2.
- --ih-apply: `-- --ih-apply=quick|old` (quick): an inserter hand update (`ih`) binds an arm to its record again only when the
- --inserter-arms-clock: - `--inserter-arms-clock=belt|wall` (belt): with `belt` the arms are drawn at the game tick the belt items
- --inserter-arms-trace: - `--inserter-arms-trace=<file>`: a JSON line per frame with every drawn hand (unit, x, y, held item),
- --inserter-events: - `--inserter-events=off|items|on` (off): with `on` (and the belt clock) the hello asks the mod for `ie`: what each
- --inserter-fast-upload: ...per-chunk `MultiMeshInstance3D` nodes; `--inserter-fast-upload=off` restores per-instance `set_instance_transform()` uploads for live inserter arms instead of b...
- --inserter-glow: - `--inserter-glow=hand|always` (hand): an inserter model's glow (a modeller's lit burner, Vasillo's
- --inserter-grip: - `--inserter-grip=on|off` (on): the item a hand carries is drawn in its grip, from the pick to the drop (owner,
- --inserter-hand-stack: - `--inserter-hand-stack=on|off` (on): stacks up to 4 held items vertically in an inserter's hand (matching belt piles via `pile_step` and `PILE_TURN`) when it carries more than one; `off` draws a single item as before.
- --inserter-handoff-margin: `--inserter-handoff-margin=N` (0): the drawn clock held N more jobs behind the game, so the job that learns
- --inserter-handoff-slack: `--inserter-handoff-slack=N` (3): the simulation is stepped at most N ticks short of the newest update so
- --inserter-rest-arms: - `--inserter-rest-arms=on|off` (on): an inserter the bridge sends no hand for draws its arm at rest, the hand
- --item-dress-usec: - `--item-dress-usec=N` (0, off): item kinds whose model or icon has come dressed for at most N µs a
- --item-geom-lod: ...stead of distance-banded MultiMeshes); `--item-geom-lod=off` (disables auto geometric LOD1 and LOD2 proxy fallback on near belt items, falling back to `--item-l...
- --item-glass: so a liquid shows inside its glass); `--item-glass=dither` dithers them in the opaque pass instead (stippled,
- --item-kinds-follow: when the packs change (an int compare a frame otherwise). `--item-kinds-follow=off`: they keep the model
- --item-light-shadows: Medium / High / Ultra (was 30 / 45 / 60 / 80). `--item-light-shadows=on` puts them back in the
- --item-lod: ...tead of smooth nearest-first scaling); `--item-lod-split=off` (legacy single-MultiMesh multi-surface shader collapse across all items instead of distance-banded...
- --item-lod-bands: ...stead of per-instance distance rings); `--item-lod-bands=all` (keeps the flat character-anchored band edges, 28 / 56 tiles at Medium, at any zoom; the default `...
- --item-lod-blend: ...0-triangle model-matched proxy boxes); `--item-lod-blend=off` (disables gradual shader shading fade and per-item distance jitter between item LOD bands); `--ite...
- --item-lod-mode: ...tem-lod=off`-controlled distance LOD); `--item-lod-mode=global` (restores legacy zoom-based global item LOD tiers instead of per-instance distance rings); `--it...
- --item-lod-split: ...tead of smooth nearest-first scaling); `--item-lod-split=off` (legacy single-MultiMesh multi-surface shader collapse across all items instead of distance-banded...
- --item-lod2: ...e 10-triangle proxy box or icon card); `--item-lod2=icon` (restores 2D Factorio icon cards at LOD2 and past `--far-belt-3d-dist` instead of 10-triangle model-ma...
- --item-materials: grey. `--item-materials=old`: as before.
- --item-models-later: - `--item-models-later=off`: an item model (items on belts, the ground, in hands) is read on the main thread the first time it is asked for, as before. On (defa...
- --item-pictures: `--item-pictures=off`: pictures left out, every item model by its colours alone (as before 0.2.2).
- --item-shadow-proxy: ...stance jitter between item LOD bands); `--item-shadow-proxy=off` (casts shadows from full item meshes instead of 12-triangle box proxies); `--item-tangents=off`...
- --item-tangents: ...s instead of 12-triangle box proxies); `--item-tangents=off` (uses screen-space cotangent derivatives instead of precomputed vertex tangents for item normal map...
- --items: `-s res://tests/belt_sim_bench.gd -- --items=80000` times it on a synthetic world.
- --job-every: `tests/belt_bs_replay.gd --every-tick=60 --job-every=30`, `tools/belt_quirks.py`) items jumping over half a
- --job-lead: `tests/belt_bs_replay.gd` sets each job's lead as the client does from `--job-every` (`--job-lead=N` to fix it;
- --join-warm: screen (`--join-warm`) waits only on pipeline_warm.gd's.
- --json: [--json <out>] [--lock <file>] [--keep <dir>] [--replay every-tick|update] [--replay-arg=<arg>] [--tail-wait 30]
- --keep-shots: that frame about half a second, so `join_hitches.py` leaves them out (`--keep-shots` keeps them).
- --kept-replay: - `--kept-replay=inline`: a kept chunk (`same`) is replayed inside that one message, as before. On:
- --lantern-shadow: ...unclipped viewport lines for 3D grass; `--lantern-shadow=cube` uses 6-face cube shadows instead of dual-paraboloid on the character lantern; `--ssil-zoom-fade=o...
- --lattice-model-cap: .../coal/stone variants past `24` tiles); `--lattice-model-cap=off` (legacy binary `< 0` all-or-nothing `Items in 3D` cap on packed lattice lanes instead of smooth...
- --lattice-variants: ...texture fetches on far 3D belt items); `--lattice-variants=close|all|off` (default `close`, switches off extra ore/coal/stone variants past `24` tiles); `--latt...
- --legacy-render: are printed and kept in the JSON's `variants`. `--legacy-render` starts with the shadows and levels
- --lock: [--json <out>] [--lock <file>] [--keep <dir>] [--replay every-tick|update] [--replay-arg=<arg>] [--tail-wait 30]
- --live-inserter-radius: - `--live-inserter-radius=detail|view|64` (detail): how far round the focus the bridge sends live inserter hands (`ih`/`ie`, moving arms; past it arms rest, K12), as the focus's `ir`. `view`: arms within the view move, up to 64 tiles: the camera's visible ground, its farthest corner's square distance from the focus plus 8 tiles, up to a step of 8, within 16..64 (about 48 at the default zoom, 64 zoomed out and in first person; a smaller radius is sent only after it stayed smaller about 1 s, so turning the view doesn't flip it; the bridge raises `f3d-detail-radius` to it, never past the Entity distance); `64`: a fixed 64-tile square (0.3.1 before this, Bug #5); `detail`: `f3d-detail-radius` alone (0.3.0, 24 tiles by default).
- --lod-anchor: ...ng real chunks then backfills with DH. `--lod-anchor=camera` turns off the character-anchored LODs. `--dh-seam-fade=off` disables smooth 0.30s Bayer cross-fade ...
- --lod-cpu-copy: - `--lod-cpu-copy=off`: reads `MultiMesh.buffer` back from the RenderingServer on LOD cross-fades
- --lod-fade-moving: - `--lod-fade-moving=off`: keep spawning LOD cross-fade nodes while moving above `12` tiles/s instead of snapping LOD transitions.
- --lod-lines: `--lod-lines=<n>` counts on n lines whatever the setting; `--lod-lines=0` counts every real line,
- --lod-low: off at roughly half the previous Low distances (`--lod-low=old` restores the prior Low values).
- --lod-mesh-touch: - `--lod-mesh-touch=off`: skips re-writing instance 0's transform after a LOD `MultiMesh.mesh`
- --lod-night-glow: ...istant-horizon-detail-lod=off|on`, and `--lod-night-glow=off|on` tune DH directly. The colour table
- --lod-pass: - `--lod-pass=every-frame`: models' levels of detail are looked at in every chunk every frame (past
- --lod-slice: - `--lod-slice=off`: disables per-chunk ring slicing and the per-frame MultiMesh switch cap
- --lods-finish-usec: - `--lods-finish-usec=N` (2000): models' levels of detail finished on worker threads are shown
- --log-file: `--log-file <absolute path>` instead (a relative path is read from the user folder):
- --logistic-status: `--logistic-status=off` disables the live fulfillment tinting on logistic request slots (restores plain slot look).
- --logs: - `tools/check.py`: `art-src/check-logs/<check>.godot.log` in the main checkout (`--all --logs <folder>`: there);
- --lose: --trace=<f3d-ih-trace.jsonl> [--events] [--lose=0.18]` the layer against a real trace, fed samples or

### Flags M–R

- --main: worktree's mod changed (copied in again); `--stop-server` stops it. `--main <checkout>` runs the same
- --map-auto-swap: `--map-auto-swap=on` restores automatic 2D/3D map swapping on zoom (zooming all the way in drops to 3D, zooming out past `map_zoom_out` returns to 2D); default `off` uses the 2D/3D toggle button in the Remote view title bar (also configurable in Settings > Camera).
- --map-surface: rails are held; `--map-surface=<index>` shows that surface on the map after 6 s and
- --md: tools/join_hitches.py out.json [--windows] [--md]` then gives frame-time percentiles, the frames over 25
- --mem-log: - `--mem-log[=<seconds>]` (off): prints a `MEM` line every 10 s (or `<seconds>`): Godot's static memory, the renderer's video/texture/buffer memory, objects, nodes, resources, orphan nodes and render pipelines compiled by kind (`debug/mem_log.gd`). Headless shows no renderer memory; run it in a window and compare with the process's RSS to see what the GPU driver holds.
- --menu-fps: ...ost (lower if the FPS limit is lower); `--menu-fps=<n>` changes it, `--menu-fps=0` leaves it uncapped as before (`settings.gd` `MENU_FPS`, `in_menu`).
- --message-catchup: - `--message-catchup=on|off` (on): while the oldest message waiting in the bridge's queue (bridge.gd
- --message-catchup-msec: `_drain`) has waited longer than `--message-catchup-msec=N` (250) since its datagram was read, the
- --mm-bounds: - `--mm-bounds=engine`: the robot swarm's, creatures' and working glow's MultiMeshes leave their own box unset, as before (perf-render R6); Godot then works their bounds out over every instance of the capacity at each buffer upload. Default: the MultiMesh gets the same box as its node (`custom_aabb`), which culls them either way.
- --mm-writes: - `--mm-writes=instance`: chunk MultiMeshes as before (perf-render R2): a per-instance write or a `mesh =` swap on one filled from a buffer makes Godot read the buffer back from the graphics card (a stall of the frame so far), and one filled instance by instance keeps the engine's CPU copy, uploaded again with every buffer. Default: changing fill way empties it first, a level-of-detail swap on a buffer-filled one re-sends the kept buffer (`chunk_view.gd`; counters `mm_fill_flips`, `mm_buf_resends`, `mm_buf_mesh_readbacks`, `mm_buf_instance_writes` under the stutter probe).
- --mod-click-probe: - `--mod-click-probe=<name>[,<name>...]`: presses mods' buttons in Zenith's copies of their windows
- --mod-click-probe-quit: and logs the windows before and after (no names: lists the buttons); `--mod-click-probe-quit`
- --mode: fixture must have none); `tools/belt_sim/sim.py rec.json --mode free` is the reference it agrees with.
- --model-load-mb: count (`load_jobs`). `--model-load-mb=<MB>` changes it, `0` no bound (count only, as before).
- --model-pictures: and textures come out the same (`tests/model_pictures_test.gd`). `--model-pictures=godot`: as before.
- --model-read-once: to Godot's reader, the pictures and a baked animation (each read it again before). `--model-read-once=off`
- --model-variants: `--model-variants=off`: always the plain model (the window still groups them), items everywhere included.
- --mover-lift: ...ns, pentapods and buildings as before. `--mover-lift=vertex`: every vertex by its own ground, as before.
- --mover-pick-all: ...tead of bulk MultiMesh buffer uploads; `--mover-pick-all` scans every GPU robot record during entity picking instead of node-backed movers; `--alt-flat-batch=of...
- --movers-dress-usec: - `--movers-dress-usec=N` (1500; 0 = all at once, as before): movers whose model has just come
- --msaa-with-smaa: `--msaa-with-smaa=on` restores stacking SMAA post-processing on top of active MSAA (`settings.gd`).
- --mv-skip-clean: `--mv-skip-clean=off` restores unconditional per-frame `item_cards.gd` motion-vector MultiMesh buffer uploads.
- --mv-skip-idle: `--mv-skip-idle=off` restores per-frame idle `write_xform` and MV buffer uploads in `robot_swarm.gd` and `creatures.gd`.
- --nack: - `--nack=off`: disables sending `{"t": "nack", "r": [...]}` requests (1–64 missing `r` sequence numbers) when the reliable
- --names: ... <names>` and `tools/models/bake_pbr.py --names <names> --fix-imports`.
- --native-bc-compress: `--native-bc-compress=off|on|force` (`on` default): enables clean-room C++ `TextureCompressNative` BC1/BC3 compression in exported builds (`off` leaves exported terrain/decoratives uncompressed; `force` exercises native BC compression in editor builds too).
- --native-chunk-build: ...cript stays when the class is missing. `--native-chunk-build=off` forces the GDScript loops. Test: `tests/chunk_build_native_test.gd`.
- --native-collect: `--native-collect=off`: every record of a chunk build walked in GDScript, as before (on: those the record cache holds walked by `ChunkBuildNative.collect_rows`; [Records resolved once](#chunk-streaming-the-views-direction-the-area-cache)).
- --native-lod-decode: - `--native-lod-decode=off`: Distant Horizon's `lod` chunk runs (`tl`, `el`) are decoded in GDScript on the main thread (lod_data.gd `from_msg_gd`), as before. On (default, with the C++ library): `WireDecodeNative.lod_cells` decodes them on the bridge's parse thread (message_decode.gd, `_lod`), or in from_msg where that thread is off (`--decode-thread=off`, the LOD cache); same cells and refusals, `tests/lod_decode_native_test.gd`.
- --native-inserter-loop: - `--native-inserter-loop=on|off` (on): with `--native-inserter-pose`, the rest of the live arms' per-arm loop runs in `InserterPoseNative` too (`frame_check`, `frame_draw`): whether each arm's record is there, the pincers' easing, the hand's moving state for the animator (L4), the held item's grabs, every arm's geometry by batch (`InserterArmsNative`'s functions) and the live set's changes, one call a frame; the GDScript handles only the arms to bind or decide a model for, hands steered onto a belt item, holding arms, and the changes. Not with `--inserter-arms-trace` or an arm without a native slot (that frame runs the GDScript loop). `off`, or a build without `frame_draw`: the GDScript loop as before (the same drawing: `tests/inserter_loop_native_test.gd`).
- --native-inserter-pose: - `--native-inserter-pose=on|off` (on): the live inserter arms' samples, events, plans and pose are kept and worked out by `InserterPoseNative` (C++, `native/belt_sim/src/inserter_pose_native.cpp`), one call a frame for every arm, the arms' loop reading each pose from its arrays. Belt clock with the pose from the samples only (the default, and `--inserter-events=off|items`); `--inserter-events=on` and `--inserter-arms-clock=wall` stay GDScript. `off`, or a build without the class: the GDScript as before (the same poses: `tests/inserter_pose_native_test.gd`).
- --native-inserter-swing: - `--native-inserter-swing=on|off` (on): the GDScript pose's plans between two hand samples (`_plan_pair`) come from `InserterSwingNative` (C++ twin of `inserter_swing.gd`, `inserter_swing_core.h`). `off`: `inserter_swing.gd` as before (the same plans: `tests/inserter_swing_native_test.gd`). Only used when `--native-inserter-pose` is off or unavailable.
- --native-inserter-ingest: - `--native-inserter-ingest=on|off` (on): the `ih` hands and `ie` events of live inserter arms already known and bound are applied by `InserterIngestNative` (C++, `native/belt_sim/src/inserter_ingest_native.cpp`) straight into `InserterPoseNative`, with `_end_frame`'s missing count and the stale sweep's `last_heard`; unknown or unbound arms, a new record and gone events go through the GDScript as before. Only with `--native-inserter-pose` on, the belt clock and `--ih-apply` (quick). `off`, or a build without the class: the GDScript as before (the same arm state: `tests/inserter_ingest_native_test.gd`).
- --native-inserter-ingest2: - `--native-inserter-ingest2=on|off` (on): with `--native-inserter-ingest`, `inserter_arms.gd`'s `_drop_arm` tells `InserterIngestNative` of every arm it drops (`drop`), so a bound arm's hand checks only its record, not the arms' map too; `_end_frame`'s missing count walks the native's own entries and the few arms it has no entry for (`_unbound`, `end_frame2`) instead of copying every arm's key and value, touching `_missing` only when it must; the once-a-second stale sweep asks the native for its stale entries (`sweep`, `last_heard` synced only for forgotten entries) and walks `_unbound` only. `off`, or a library without `end_frame2`: as before (the same arms: `tests/inserter_ingest_native_test.gd`, with timings at 5,000 arms).
- --arm-bind-layout: - `--arm-bind-layout=on|off` (on): a live inserter arm's bind (`_bind`: base, direction, colour, model name, `ModelLibrary.placed`, chunk) is redone when the packs' version or `ModelLibrary.layout_generation` (bumped by `choices_changed` and the packs' zips coming in) changes, not whenever any model finishes (`ModelLibrary.generation`, up every frame a model is made while a base loads: each bump sent every arm's next hand through the full bind and `InserterIngestNative.unbind_all`). `--stutter-probe` counts `arm_unbind_all`, `ih_back` (hands handed back to the GDScript) and `arm_new`. `off`: as before (the same arms: `tests/inserter_bind_stamp_test.gd`).
- --arm-model-watch: - `--arm-model-watch=on|off` (on): the inserter arms' draw modes (`_decide_mode`, `_push_draw`, the native loop's `clear_modes`) and resting arms (their whole rebuild and per-chunk index stamp) follow a stamp of the arms layer's own (`_model_ver`) instead of `ModelLibrary.generation`: the model names the lookups were told "not ready" (rigs, pack rigs, Wube's arm pieces) are kept and asked again when the generation changes, and the stamp goes up only when one became ready; a safety net takes the raw generation once one has stayed untaken for 2 s (trailing), and the stamp is worked out once a frame. While a base loads, models finishing elsewhere no longer re-decide every arm and rebuild every chunk's resting arms each frame. `--stutter-probe` counts `arm_modes_cleared` and `arm_rest_all`. `off`: `ModelLibrary.generation`, as before (the same drawing: `tests/inserter_model_watch_test.gd`).
- --native-lod-mesher: - `--native-lod-mesher=off`: Distant Horizon's section meshes (lod_mesher.gd) and the far chunks' merged meshes (far_chunks.gd, Merge) are built in GDScript, as...
- --near: (the High distances by default: `--near 160`, `--cap 6000`, `--units` for Smooth belt items),
- --night-vision-fx: - `--night-vision-fx=off`: no night vision feedback: no sound as it turns on or off (the equipment's own
- --no-belt-stand-ins: the main thread instead of a worker, for comparing. `--no-belt-stand-ins` draws every belt whole
- --opaque-blend: contact shading. `--opaque-blend=off` keeps every BLEND material see-through.
- --optimistic-cache: - `--optimistic-cache=off`: wait for server `same` before mounting RAM/disk-cached chunks when re-entering an area.
- --optimistic-slice: - `--optimistic-slice=off`: replay a cached chunk (RAM or disk cache) whole in one call, the clock checked only between chunks, as before. On (default): one ste...
- --ents-slice: - `--ents-slice=off`: a packed `ents` message (a cache replay's step, or a live one while messages drain) applied whole, as before. On (default): `ENTS_SLICE` (64) records a step, the joins flushed after each, the part noted after the last; the chunk replaying isn't built until its replay is done; a live message's later slices go in front of the waiting messages (not for `same`'s replayed ones). Also joins a multi-part cache entry with `append_array` and sorts the optimistic queue by packed keys only when it or the focus changed.
- --oracle-at: `tools/bs_offline.py` from a recording serves too.) Experiments: `--oracle-at=TICK` reads every recorded lane
- --ore-density: `--ore-density=classic`: 0.2.2's first scattering, 2, 4 or 6 rocks (under 400, from 400, from 2900; uranium 270
- --ore-look: `--ore-look=old`: a "pbr" pack's ore rocks drawn as any model (Burley diffuse, the file's occlusion picture on ambient)
- --ore-scatter: `--ore-scatter=auto` (default) as said; `--ore-scatter=on` scatters any plain ore model too, and a pack whose
- --out: `python tools/belt_ring.py --out <dir> [--puts 10,17] [--watch 5,12]` makes a moving ring the same way (replayed with
- --pan: `@pan` moves Factorio's view one pixel a frame instead. `python tools/flicker_count.py` (`--pan`)
- --perf-warning: - `--perf-warning=off`: starts with the performance warning hidden (until Settings > Interface > Performance
- --period: --f --takers 2 --takers-from 10 --period 15 --take-window 100,900 --release 300,700`, replayed as below at
- --persist: `--reads-after=none` then applies no lane reads (the simulation alone), `--persist` says per update
- --pipe-covers: `--pipe-covers=off`: none; `--pipe-covers=own`: extract from each entity's own drawing pack ending instead of following the active pipe pack (`pipe_covers.gd`).
- --covers-batch: `--covers-batch=off`: each machine's pipe covers worked out again as every record of an `ents` message comes (its own, every neighbour's, every machine facing a pipe), as before. On (default): while a message's joins are batched, connections are only noted and the machines whose covers may change are covered once when the joins are flushed (`add_covers` in `--stutter-probe`, inside `add_joins`); connections' turned offsets and `PipeCovers.ports` kept per prototype; `_forget` skips the pipe/wall/belt tables a record's prototype isn't in (with `--world-fast-add`).
- --pipe-fluids: (`--pipe-insides=off` skips that), and the fluid inside is drawn behind the glass (`--pipe-fluids=off` hides it).
- --pipe-insides: (`--pipe-insides=off` skips that), and the fluid inside is drawn behind the glass (`--pipe-fluids=off` hides it).
- --pipe-warm-extra: - `--pipe-warm-extra=off`: the hover marks', Alt-mode's card shader's and the post effects' (SSAO, SSIL, glow, grade, fog, shadowed sun) pipelines are built whe...
- --pipe-windows: `--pipe-windows=off`: none of the window models, insides or pipe fluids.
- --pipeline-warm: first fill or another process on the PC. With main's `--pipeline-warm` (pipeline_warm.gd, below) both
- --ports: --worktree <checkout> --ports <udp>,<game>,<rcon> [--at x,y] [--size 64] [--seconds 10] [--settle 40]
- --power-bar: `--power-bar=middle` (or `old`): restores the old yellow armour battery bar above the middle quickbar and character health beside the bottom-left armour slot; default shows armour battery power beside the bottom-left armour slot while the middle shows only health and energy shield.
- --predict-probe: - `--predict-probe=<out.json>[@builds]`: builds a wooden chest beside the character over and over
- --prio-delta-order: - `--prio-delta-order=off`: a chunk's `add`/`upd`/`del` may take the priority lane while an older delta for the same
- --priority-queue: - `--priority-queue=on|off` (on): movement commands (`walk`, `drive`, `enter`) send directly on input events and
- --probe-ab: ...at much slower, as a dense base's are. `--probe-ab=3` measures each variant three times between two "base" steps, which
- --probe-fine: single-player needs no RCON; `--probe-fine` keeps subtrees over 0.005 ms, not only over 0.1.
- --probe-frame-sleep: `--probe-frame-sleep=<ms>` makes every frame that much slower, as a dense base's are. `--probe-ab=3` measures each variant three times between two "base" steps,...
- --probe-render-times: `--probe-render-times` (each read waits for that thread). `--belt-items-sync` handles belt items on
- --probe-shot-after: written to the run's own user folder, then stands 10 s (`--probe-shot-after=<s>`): the shot's frames are
- --probe-shot-camera: `@shot` (L14) takes the camera up (`--probe-shot-camera=<height>,<pitch>[,hand]`, default 250 tiles at 22
- --probe-shots: left to build, `--probe-shots=<dir>` saves a screenshot of each step. Each step's medians (frame,
- --probe-stay: sets the seconds to settle and to measure, `--probe-stay` leaves the client running after the summary
- --probe-timing: cancels the graphics card's drift (compare each with the bases beside it), `--probe-timing=2,4`
- --probe-trace: `--probe-trace`, its walk summary and the bridge's f3dtrace lines read back as the earlier
- --probe-unload: counts (`--probe-unload` adds them to any route: chunks loaded, drawn, drawn past the square, kept past it,
- --probe-unload-walk: behind-cull hidden and queued, far merging's queues, the budget's grants); `--probe-unload-walk` also walks
- --probe-variants: exoskeletons make that 30-40 tiles a second), `@stand` stays put, `@variants` with `--probe-variants` (or `--probe-variants=ssao off,trees
- --probe-warmup: (a harness that takes screenshots after the route ends it), `--probe-warmup=30` waits longer and until no chunk is
- --profile: and "Entity distance". `python tools/ups_probe.py --port <rcon> --seconds 30 --profile`
- --puts: `python tools/belt_ring.py --out <dir> [--puts 10,17] [--watch 5,12]` makes a moving ring the same way (replayed with
- --python: ...`blender --background --factory-startup --python tools/models/nature/build_nature.py -- <names>`, then `tools/models/part_colors.py <names>` and `tools/models/b...
- --quality-marks-static-cache: ...`, `alt_overlay.gd`, `alt_arrows.gd`): `--quality-marks-static-cache=off` rebuilds all entity quality-mark transforms every refresh instead of caching static en...
- --queue: lane reads: `--belts 40 --queue 36 --take 25 --feed 6 --ticks 2400 --hands-radius 4`, replayed with
- --quit-probe: - `--quit-probe=<seconds>`: quits after that long without the exit guard, so a hang on quitting
- --rail-from: distance (under 40 tiles, up close too); `--rail-from=<x>,<y>` starts the rail planner there once
- --read-probe: (with belt_sim.gd, only lanes whose items go on into recorded lanes alone); `--read-probe` (belt_sim.gd)
- --reads-after: `--reads-after=none` then applies no lane reads (the simulation alone), `--persist` says per update
- --record-bounds: [--record-bounds view|square] [--draw-dump on|off] [--client-arg=<arg>] [--client-setting=<key>=<value>]`. It starts that checkout's server on a copy of its `se...
- --release: --f --takers 2 --takers-from 10 --period 15 --take-window 100,900 --release 300,700`, replayed as below at
- --reliable-reorder: - `--reliable-reorder=off`: reliable messages that arrive after a NACKed gap are handled at once, before the
- --relief-fade: and aren't made past that; off altogether at Level of detail Low. `--relief-fade=off` keeps them at
- --remote-surface: `--remote-surface=<index>` its world in the remote view; `--update-rate=<0-3>` asks the bridge
- --render-distance-split: ... `graphics.distant_horizon_manual`, or `--render-distance-split=manual`) `Settings > Graphics` has separate `View distance (full)` (`graphics.view_radius`, `2.....
- --render-reads: - `--render-reads=old` (and the setting Graphics > "Render on a separate thread", on by default, off = the main thread draws as before; needs a restart): with t...
- --render-thread: `user://engine.cfg`), or start once with `--render-thread safe` before the `--`.
- --replay: [--json <out>] [--lock <file>] [--keep <dir>] [--replay every-tick|update] [--replay-arg=<arg>] [--tail-wait 30]
- --replay-arg: [--json <out>] [--lock <file>] [--keep <dir>] [--replay every-tick|update] [--replay-arg=<arg>] [--tail-wait 30]
- --replay-bre: `--replay-bre` so the client's re-reads are answered, as the bridge answers them live).
- --drain-head-again: - `--drain-head-again=on|off` (on): when a message the messages' slice handles puts entries in front of the waiting messages (`requeue_front`: a live `ents` message's later slices), the slice runs them in the same drain while its time lasts. `off`: the slice stopped at them and they waited for the next frame, as before (`tests/bridge_queue_stress_test`).
- --replay-kinds: - `--replay-kinds=on|off` (on): a kept message the bridge hands again (`Replay`, world.gd's kept chunks via `requeue_front`) carries its message type, so the messages' slice guesses its cost by type (`FrameBudget.item_est` `replay:<t>`: a kept chunk's `ents` costs far more than its `cq`) and `--stutter-probe` names it `replay:<t>`; the probe also times the fast lanes one message at a time (the frame's slowest message) with parts `br_me`, `br_prio`, `br_live`, `br_belt` (`br_fast`'s shares). `off`: one `replay` estimate for all kept messages, as before. The handled order is the same either way (`tests/bridge_queue_stress_test`).
- --rest-arm-basic: - `--rest-arm-basic=live|stick` (live): an inserter with no arm model (a mod's: no rig, no Wube pieces) rests drawn as its live arm is (the placeholder arm: turntable, shoulder post, upper arm, forearm, hand and two fingers in its prototype's colours, `Visuals.instance_material`, casting shadows) in the per-chunk resting MultiMeshes. `stick`: as before 0.3.1, a thin 3-box stick in the rest shader without a shadow (about 7 instances an arm instead of 3, up to 6 MultiMeshes a chunk instead of 1).
- --rest-arm-shadows: - `--rest-arm-shadows=live|tier` (live): a resting 3D inserter arm casts its shadow wherever a live arm would (live arms always cast): in every chunk whose shadows reach the ground in view, at every Level of detail. `tier`: as before 0.3.1, in chunks past the ring round the character (shadow tier FAR) only on High/Ultra (`--inserter-shadows`). Costs on Low/Medium about one shadow-pass draw per far chunk with resting arms per arm mesh (a rig's 4-5, Wube's pieces 2, the placeholder's 6).
- --rest-arms-chunked: ...polling/uploads in `quality_marks.gd`; `--rest-arms-chunked=off` rebuilds one global resting-arms `MultiMesh` buffer instead of updating only dirty per-chunk `M...
- --rest-arms-index: - `--rest-arms-index=on|off` (on): resting inserter arms come from a per-chunk index of its inserters and belts (one walk of the chunk, made again when its entities change), their 3D and picture arms posed by `InserterArmsNative` a model at a time (inputs kept per inserter), a new arm's belt at its pickup looked up in the cells round it, and the resting arms' shadow settings checked 32 chunks a frame. `off`: as before (every entity of the chunk walked, each resting arm posed in GDScript, every chunk's shadow every frame).
- --rest-arms-region: - `--rest-arms-region=<n>|off` (2): resting 3D inserter arms of n x n chunks (2: 64 x 64 tiles; 4 culls coarsely and drew the most triangles in the bench) are drawn by one `MultiMeshInstance3D` per arm mesh instead of one per chunk (each also one draw in every shadow pass). The per-chunk work is unchanged (worked out when a chunk's entities or live arms change); only the upload joins the region's chunk buffers when any of them changed. Same meshes, layouts, materials, colours and poses; a region casts shadows if any of its chunks would (`--rest-arm-shadows` per chunk as before) and shows if any of its chunks shows; Godot works out its bounds from its instances. `off` (or `1`): one per chunk, as before.
- --resolve-memo: `--resolve-memo=off`: a record's model, readiness and parts asked of ModelLibrary in three calls and its contact rings worked out every build, as before (on: `resolve_entity`, kept per generation, rings kept on the record); the records `--native-collect` walks still append their kept rings, so turn both off for the old path in full.
- --resync-guard: - `--resync-guard=on|off` (on): a slow join can't loop. `off`: as before. Why: on a slow PC (the second PC,
- --reuse-server: updates|tick] [--camera top|free|<yaw,pitch,dist[,ortho]>] [--stand-in] [--reuse-server] [--shots <dir>]
- --review-aim: tools/models/review.py starts) with `--review-box=<w>,<d>,<h>`, `--review-aim=<height>`,
- --review-box: tools/models/review.py starts) with `--review-box=<w>,<d>,<h>`, `--review-aim=<height>`,
- --review-fly: `--review-views=<a,b,...>` and `--review-fly=<path.json>` (a camera flight);
- --review-views: `--review-views=<a,b,...>` and `--review-fly=<path.json>` (a camera flight);
- --rig: Checked by model_textures_test.gd (`-- --rig=<a modeller's inserter.glb>` for theirs) and
- --robot-nodes: `--robot-nodes` draws robots a node each, as before robot_swarm.gd, for comparing.
- --robot-probe: - `--robot-probe=<out.json>[@seconds]`: stands still and records what each frame costs with the
- --robot-sim: - `--robot-sim=on|off` (on): simulate worker robot flight on the client and GPU (`rb`, wire version 4, smoothly crossing Factorio 2.0/2.1's 20-tick position-lim...
- --robots: movers in view (frame, movers' script time, draw calls, GPU); with the mock's `--robots N`.
- --runs: `--groups` to say `bg` too, `--runs` to say `br` (straight runs moved by the client). It warms up for

### Flags S–Z

- --sample: (`tools/belt_sim/record.py --sample updates`: only the ticks the bridge sends an update on, all the
- --scene: item-seconds (`tools/belt_quirks.py`; on the take's lane 13.6 -> 0.3%); `tools/belt_build_mine.py --scene
- --seconds: and "Entity distance". `python tools/ups_probe.py --port <rcon> --seconds 30 --profile`
- --settings: [--settle-max 180] [--first-bs 60] [--settings automatic|unlimited] [--hold60 on|off] [--record
- --settings-probe: - `--settings-probe=<folder>[@seconds]`: after 25 s (or the seconds given) changes every row of the
- --settings-probe-restart: put back afterwards. `--settings-probe-restart` then writes a set of non-default values for the next
- --settings-probe-verify: start, which `--settings-probe-verify` reads back in the game (`<folder>/verify.txt`). Use a user
- --settings-scroll-to: - `--settings-scroll-to=<control name>` (with `--menu=settings:<tab>`): that setting scrolled into
- --settle: --worktree <checkout> --ports <udp>,<game>,<rcon> [--at x,y] [--size 64] [--seconds 10] [--settle 40]
- --settle-max: [--settle-max 180] [--first-bs 60] [--settings automatic|unlimited] [--hold60 on|off] [--record
- --shader-refresh: **Shader refresh** (on by default; `-- --shader-refresh=off` skips it, `--shader-refresh=force` refreshes this start): a new build's first start (a new stamp in...
- --shadow-filter: `--shadow-filter=old` puts back the soft filters from before the shadows' steps 2-3: Soft Low (4 taps)
- --shadow-fit: `--shadow-fit=old` fits the sun's shadow map as before the shadows' stability work: whether the view
- --shadow-pancake: small and dense (`--shadow-pancake=<tiles>` sets it). Anti-aliasing is unchanged: no screen-space AA
- --shadow-runs: ...date only boundary diffs when panning. `--shadow-runs=off` and `--far-decide-runs=off` rescan all loaded chunks; `--far-prep-guard=off` skips cancelling in-flig...
- --shadow-small: - `--shadow-small=old`: every model in a chunk casts into the sun's shadow map at every shadow tier, as before. On (default): models whose top is under 0.08 til...
- --share-textures: kept apart from its smooth use. `--share-textures=off`: every model its own copies.
- --shots: updates|tick] [--camera top|free|<yaw,pitch,dist[,ortho]>] [--stand-in] [--reuse-server] [--shots <dir>]
- --shut: Offline (`tools/belt_bursts.py --mode out --open 99999,99999 --shut 1,1 --feed --feed-loose 0.1 --tier yellow
- --signal-skip-same: `--signal-skip-same=off` refreshes every rail/chain signal glow every 0.5 s as before (`signal_lights.gd`); on, an unchanged refresh keeps its glows.
- --signal-omni-lights: `--signal-omni-lights=on` restores pooled `OmniLight3D` nodes on rail/chain signals (`signal_lights.gd`; off by default).
- --sim-dump: the bridge offline; `tests/belt_bs_replay.gd --every-tick --ie-wire=0 --sim-dump= --belt-draw-dump=` replays
- --sim-dump-near: `draw.bin.apply.jsonl`) came within a point of the live run's frozen and sliding shares. `--sim-dump-near` (with
- --size: --worktree <checkout> --ports <udp>,<game>,<rcon> [--at x,y] [--size 64] [--seconds 10] [--settle 40]
- --soak-probe: - `--soak-probe=<out.json>[@minutes]`: a long session (30 minutes): walks a square, opens windows,
- --soft-shadow-atlas: of detail from before sun_shadows.gd, for a whole run. `--soft-shadow-atlas=4096` caps the sun's shadow map at 4096 while the
- --source: missing (0.8%), and the far end of `tools/belt_build_mine.py --source` flapped every 24 ticks.
- --spacing: 99.91%; `--scene mine --source --spacing 64` (K22, a packed moving line): phantoms 2.06 -> 0.16% of what is drawn
- --spike-log: **The spike log** (`-- --spike-log[=ms]`, or the debug menu's Tests → Spike log; off by default;
- --spike-render: `--spike-render=off`: a spike line without its render part (draw calls, the viewport's measured CPU/GPU ms, the renderer's stages with Godot's `--gpu-profile`) and with the draw bucket even with the render thread on, as before (PROFILING-NOTES, the spike log's render part).
- --split-reconcile: 5.92% -> 2.83% off on rec80, 6.18% -> 4.20% on rec80b (belt_sim_replay.gd `--split-reconcile=off`).
- --split-wake: belt_sim_replay.gd `--split-wake=old`, tools/belt_sim/sim.py `--wake-rule r0|r4`). Splitters with a priority
- --ssil-zoom-fade: ...l-paraboloid on the character lantern; `--ssil-zoom-fade=off` leaves SSIL on across all zooms instead of fading out alongside SSAO.
- --st-slice: `-- --st-slice=on|off` (on): a machine states message (`st`) of more than 64 states waits in world.gd and is applied
- --stall-watchdog: **The stall watchdog** (on by default; `-- --stall-watchdog=off`, `--stall-watchdog=<seconds>` for its wait, 5 unless
- --stand-in: updates|tick] [--camera top|free|<yaw,pitch,dist[,ortho]>] [--stand-in] [--reuse-server] [--shots <dir>]
- --stand-in-cap: --bs --capture` instead of Zenith (no Godot, no screenshots: for bridge-only runs; `--stand-in-cap`,
- --stand-in-near: `--stand-in-near` are its `bfar`). `--reuse-server` keeps the server running on its save copy after the
- --status: run.json beside the stream, or `--status`, `--settings-file`) and how the replay ran. The headline
- --stop-labels: `--stop-labels=alt` restores floating 3D train station names over stops while Alt-mode is on (default `map`: station names show only in map view).
- --stop-server: worktree's mod changed (copied in again); `--stop-server` stops it. `--main <checkout>` runs the same
- --stream-lookahead: - `--stream-lookahead=off`: disable flight-velocity priority biasing along movement direction.
- --stream-window: - `--stream-window=legacy|<N>`: restore fixed `STREAM_MOVING = 12` / `STREAM_STILL = 32` non-sliding subscription throttling (`legacy`), or force a custom in-fl...
- --sub-incremental: ...ows` directly without hashing vectors. `--sub-incremental=off` rebuilds wanted/subscribed lists in full.
- --sun-step: arms, so the filter is made to leave none. `--sun-step=<degrees>` (measuring only; 0, the default, is
- --systems: buildings being drawn. `python tools/moving_summary.py run.json ... --systems` summarises runs: the
- --tail-wait: [--json <out>] [--lock <file>] [--keep <dir>] [--replay every-tick|update] [--replay-arg=<arg>] [--tail-wait 30]
- --take: lane reads: `--belts 40 --queue 36 --take 25 --feed 6 --ticks 2400 --hands-radius 4`, replayed with
- --take-window: --f --takers 2 --takers-from 10 --period 15 --take-window 100,900 --release 300,700`, replayed as below at
- --taker-every: 0.69 / 1.63 / 0.70%, phantoms 7.95 / 8.20 / 7.96%, hops 139 / 22 / 47; with `--taker-every 12 --hands-radius 4`
- --takers: --f --takers 2 --takers-from 10 --period 15 --take-window 100,900 --release 300,700`, replayed as below at
- --takers-from: --f --takers 2 --takers-from 10 --period 15 --take-window 100,900 --release 300,700`, replayed as below at
- --tank-window: - **Storage tank level window**: off by default (owner); `--tank-window=on` draws it again (`fluids_power.gd` `tank_windows`).
- --teleport: --udp-port 34200 --teleport -272,-16 --seconds 40 --json out.json` against a running server (on a
- --terrain-layers: (`--terrain-layers`, below) the array has room: a new kind of ground is written into its own layer on
- --terrain-native: ...4,000 buildings 1.0-1.4 s -> 37-55 ms. `--terrain-native=off` (or the add-on's setting off, or a platform without the library): its GDScript, as before.
- --terrain-opt: sets a parameter on both ground materials. `--terrain-opt=old` brings back one surface and `terrain_old.gdshader`
- --terrain-probe: - `--terrain-probe`: every 5 s prints how long chunks waited for their tiles and their ground, and
- --terrain-upload-thread: - `--terrain-upload-thread=on` (the default; off as before): the terrain Texture2DArray (every layer
- --tex-cache: the oldest going first. `--tex-cache=off` (shared with the ground's textures): no disk cache.
- --textured-lod: - `--textured-lod=legacy`: restores the fixed `[64, 32]` px switch sizes and `[0.3, 0.15]`
- --ticks: lane reads: `--belts 40 --queue 36 --take 25 --feed 6 --ticks 2400 --hands-radius 4`, replayed with
- --tier: `python tools/belt_bursts.py --out <dir> --mode out|take [--tier turbo]` makes the scenes (its header says how
- --tile: [rec.json] [--bench] [--tile=N]` starts from the recording's first tick, steps on by itself given only what
- --trace: --trace=<f3d-ih-trace.jsonl> [--events] [--lose=0.18]` the layer against a real trace, fed samples or
- --tree-impostor: `--tree-impostor=off` disables solid non-discard crown shadow hulls, coarsened wood shadow indices, and the 4th far tree LOD tier in `model_lods.gd`.
- --tree-lod: - `--tree-lod=off`: disables card-level view LODs on trees, keeping full leaf cards at every distance as before.
- --tree-shadow-decimate: ...ps vertex-stage lane distance culling; `--tree-shadow-decimate=off` keeps all non-core leaf cards in tree shadow stand-ins; `--far-coarse=off` disables the oute...
- --tree-sheen: Trees (and rocks with grain): `--tree-sheen=old` (also `--grass-backlight=old`) keeps the 0.2.2 specular 0.5-0.2; default is matte (0.05, roughness 1). `--night...
- --truth: `godot --headless --path client -s res://tests/belt_bs_replay.gd -- --stream=bs.jsonl --truth=rec.json
- --udp-port: --udp-port 34200 --teleport -272,-16 --seconds 40 --json out.json` against a running server (on a
- --units: (the High distances by default: `--near 160`, `--cap 6000`, `--units` for Smooth belt items),
- --unload-fast: - `--unload-fast=off` (P4: "5 seconds after looking away to gain FPS", "running leaves rendered chunks and LODs"): restore the old unloading. On (default): the ...
- --update-rate: `--remote-surface=<index>` its world in the remote view; `--update-rate=<0-3>` asks the bridge
- --view: `--view=-4,4,52,13` and scored by `tools/belt_quirks.py --every 30`, draws stop-and-go lanes standing (E46).
- --view-drift: item is in view; `--view=x,z,w,h` gives the ground view the records are planned for, moved `--view-drift=dx`
- --view-dump: replays the capture through that build's belt_items.gd (`tests/belt_bs_replay.gd --view-dump
- --wake-prio: or a filter stay out of it (tools/belt_sim/sim.py `--wake-prio` shows it worse on one recording).
- --wake-rule: belt_sim_replay.gd `--split-wake=old`, tools/belt_sim/sim.py `--wake-rule r0|r4`). Splitters with a priority
- --walk-shape: `--walk-shape=off`: a chunk's first build resolves every record in GDScript (`_walk_rec`), as before (on: records whose shape a build already resolved get their row from the shape's template in `ChunkBuildNative.collect_rows`; [A chunk's first build from shape templates](#chunk-streaming-the-views-direction-the-area-cache)).
- --warm-rings: ...eps full-detail meshes for far ghosts; `--warm-rings=<n>` sets warm ring retention (`0..12`, default `4`); `--belt-lane-vcull=off` skips vertex-stage lane dista...
- --warm-shaders: - `--warm-shaders=loaded|all|cold|off` (loaded): shader_warmup.gd uses the world's shaders once while the client starts (`all` or cold start compiles all; warm `loaded` touches cached batches; `cold` skips on warm launches; `off` skips).
- --worker-threads: - `--worker-threads=all|<n>` (headroom cap in `user://engine.cfg`): caps `threading/worker_pool/max_threads` so background shader/asset jobs leave CPU cores free for the OS and other apps (`all` or `-1` uses Godot's default `-1`).
- --warmup: `--warmup` seconds (20 by default) and then records the bridge's per-module times, the game's UPS,
- --watch: `python tools/belt_ring.py --out <dir> [--puts 10,17] [--watch 5,12]` makes a moving ring the same way (replayed with
- --windows: tools/join_hitches.py out.json [--windows] [--md]` then gives frame-time percentiles, the frames over 25
- --within: `check truth.json drawn.json [--within x0,y0,x1,y1]` compares where the client drew them with
- --worktree: --worktree <checkout> --ports <udp>,<game>,<rcon> [--at x,y] [--size 64] [--seconds 10] [--settle 40]
- --world-fast-add: ...cargo joins per `"ents"` chunk packet. `--world-fast-add=off` classifies and joins each record individually.
- --worm-state: to step through a loop, as each screenshot takes longer than a frame) and `--worm-state=<0|1|2>`

## Menu, Launch, Mock, Relay & Native Switches (from Running Guide)

Flags consolidated from [RUNNING.md](RUNNING.md) so the running guide stays scannable while keeping every `--flag` documented.

### Graphics, Upscaling & Native Fast-Paths

| Switch | Default | Purpose |
|---|---|---|
| `--rendering-driver d3d12\|vulkan` (Godot's own, before `--`) | `d3d12` on Windows | The renderer for this start, over **Settings → Graphics → Renderer** (`graphics.renderer`, written to `user://engine.cfg` as `rendering/rendering_device/driver.windows`; applies after a restart). Direct3D 12 is the Windows default since 0.3.1 (about half Vulkan's memory in the overnight soak); `project.godot` falls back to Vulkan when Direct3D 12 can't start. Linux and macOS unchanged. The shader refresh's restart keeps it, and the staged shader warm-up runs once per driver (`driver=` in `user://build-stamp.txt`). |
| `--upscaler=bilinear\|fsr1\|fsr2\|fsr3\|fsr4\|dlss\|auto` | the setting (`fsr2`) | 3D viewport upscaler for one run, over **Settings → Graphics → Upscaling** (`fsr` aliases `fsr1`; `fsr2.1`/`fsr2.2` alias `fsr2` for AMD FSR 2.2 Temporal; `fsr4` is AMD FSR 4.1, Radeon RX 6000 or newer, `fsr3` AMD FSR 3.1, any GPU; `fsr4.x`/`fsr3.x` alias them). `fsr4`, `fsr3`, `dlss` and `auto` need a build with the engine hook and the vendor runtime (none yet, [RUNNING.md](RUNNING.md#upscaling)): until then `fsr4`/`fsr3`/`dlss` draw with FSR 2.2 (`fsr4` on a PC without a supported Radeon: FSR 3.1 where that can run) and `auto` picks FSR 2.2. An unknown value is `fsr1`, as before. |
| `--fsr2-fixes=old` | current fixes | Restores pre-fix LookPass reactive alpha, sharpening, and orthographic FSR2 fallback behavior. |
| `--temporal-motion-vectors=on\|off` | `on` | Toggles native MultiMesh per-instance motion vectors for moving belt items, robots, and creatures under TAA / FSR 2.2. |
| `--temporal-mv-bands=0\|1\|all` | `0` | Belt item bands writing native motion vectors (`0`: close Band 0 only; `1`: +Band 1; `all`: all; Band 2 stays GPU-record). |
| `--belt-mv-native=off` | native | Forces the GDScript `BeltMv` fallback instead of native C++ motion-vector transforms. |
| `--belt-reactive-mask=on\|off` | auto | Toggles the FSR 2.2 belt-surface reactive mask `next_pass` and `belt_smear` re-enable. |
| `--no-belt-smear` | smear on | Disables one-frame fast-belt smear (compare cleanly without TAA/motion blur). |
| `--native-belt-items=off` | native | Forces ItemCards per-frame MultiMesh hand-over back to GDScript instead of `BeltItemsNative`. |
| `--native-inserters=off` | native | Forces GDScript inserter arm transforms instead of `InserterArmsNative`. |
| `--native-inserter-loop=off` | native | The live inserter arms' per-arm loop (bind checks, pincers, moving state, batches) in GDScript instead of `InserterPoseNative.frame_draw`. |
| `--native-inserter-pose=off` | native | Live inserter arms' samples, events and pose kept and worked out in GDScript instead of `InserterPoseNative`. |
| `--native-inserter-swing=off` | native | The GDScript pose's swing plans from `inserter_swing.gd` instead of `InserterSwingNative`. |
| `--native-inserter-ingest=off` | native | Inserter arms' `ih` hands and `ie` events taken in GDScript instead of `InserterIngestNative`. |
| `--native-inserter-ingest2=off` | native 2 | `InserterIngestNative` checks each hand's arm in the arms' map, and `_end_frame` and the stale sweep walk every arm. |
| `--arm-bind-layout=off` | layout stamp | Inserter arms bind again (base, colour, placement) whenever any model finishes (`ModelLibrary.generation`), and `InserterIngestNative` hands every arm back to the GDScript then. |
| `--arm-model-watch=off` | watched names | Inserter arms' modes are decided again and every chunk's resting arms rebuilt whenever any model finishes (`ModelLibrary.generation`). |
| `--rest-arms-index=off` | indexed + native | Resting inserter arms walk every entity of their chunk and are posed in GDScript; `_belt_at` walks the chunk; every chunk's resting-arm shadow is checked every frame. |
| `--native-movers=off` | native | Forces GDScript motion-vector transforms for robots and walking creatures instead of `MoversNative`. |
| `--native-decor=off` | native | Forces GDScript per-chunk decoratives build instead of `DecorNative`. |
| `--weather-rain-zoom=old` | grows | Immersive Weather's rain keeps its 48-tile box round the focus when zoomed out (a dot on screen) instead of growing with the camera's distance. |
| `--enemies-native=off` | native | Immersive Enemies' ragdoll limbs and separation, gore and acid goo step in GDScript instead of `BiterRagdollNative`, `BiterGoreNative`, `AcidGooNative` (add-on setting *Fast native simulation*). |
| `--enemies-burst=old` | spread | Immersive Enemies draws every death of a frame at once (a grenade into a horde: 25-35 ms for 80 deaths), sprays every hit at once, and api.creatures throws its cut legs/parts away whenever any model finishes loading, as before 0.1.2 (add-on setting *Spread death effects over frames*). |
| `--static-mv=old` | `f3d_time` | Standing buildings read Godot `TIME` again, putting static geometry into TAA/FSR2 motion vectors. |
| `--merged-materials` / `--no-merged-materials` | off (auto-on in Recommended) | Draws each model as one surface/material (fewer draw calls, slightly higher GPU cost; takes effect on restart). |
| `--tree-impostor=off` | on | Restores alpha-tested tree leaf shadow cards and 3-tier tree far LODs (`model_lods.gd`). |
| `--fx-opt=off` | on | Restores linear array erasures and uncached/unculled trail updates (`sprite_fx.gd`, `weapon_fx.gd`). |
| `--signal-omni-lights=on` | off | Restores pooled `OmniLight3D`s on rail/chain signals (`signal_lights.gd`). |
| `--budget-floor-cap=off` | on | Restores uncapped stacking of non-`messages` `FrameBudget` floors (`frame_budget.gd`). |
| `--mv-skip-clean=off` | on | Restores unconditional per-frame `item_cards.gd` motion-vector MultiMesh uploads. |
| `--mv-skip-idle=off` | on | Restores per-frame idle `write_xform` and MV buffer uploads in `robot_swarm.gd` and `creatures.gd`. |
| `--msaa-with-smaa=on` | off | Restores stacking SMAA post-processing on top of active MSAA (`settings.gd`). |
| `--hover-highlight-cache=off` | on | Restores rebuilding hover/build highlights every frame even when unchanged (`player_input.gd`). |
| `--belt-mid-lod=off` | on | Disables the 3D mid-detail belt LOD tier (`belt_lods.gd`, `chunk_view.gd`), restoring Full/Flat only. |
| `--native-bc-compress=off\|on\|force` | `on` | Controls C++ `TextureCompressNative` BC1/BC3 compression in exported builds (`force` uses it in editor too). |
| `--belt-mv-change-flag=off` | on | Hashes every emitted belt motion-vector buffer again (`belt_mv.gd`, `item_cards.gd put_mv`) instead of the native evaluator's change flag. |
| `--belt-mv-partial=off` | on | Restores unconditional `BeltMv` MultiMesh buffer syncs even on settled/off-screen frames (`belt_mv.gd`). |
| `--belt-mv-threads=off` | on | Evaluates the belt motion-vector kinds one after another on the main thread (`BeltMvNative.step`) instead of in parallel on the worker pool. |
| `--belt-mv-tight-cap=off` | on | Sizes belt motion-vector buffers to the records' capacity instead of the items (`BeltMvNative`). |
| `--belt-mv-page-dirty=off` | on | A record page update re-evaluates whole belt motion-vector kinds instead of the touched pages' slots (`BeltMvNative`). |
| `--belt-mv-native-put=off` | on | Hands every changed belt motion-vector buffer to GDScript's `put_mv` instead of putting steady kinds from `BeltMvNative.step`. |
| `--cloud-ray-opt=off` | on | Disables 2x empty-space stepping and far/opaque detail skip in volumetric clouds (`cinematic_grade.gdshader`). |
| `--ssao=on\|off` | preset / High | Overrides Ambient Occlusion for a single run. |
| `--model-look=palette` | standard | Draws built-in models in their unweathered palette colours for visual comparison. |
| `--item-models=off` | `on` | Draws every belt/ground/hand item as its 2D icon instead of 3D item meshes. |
| `--item-bench` | off | Prints frame times and belt-item timings every 5 s (used with mock `--belt-field`). |
| `--server-first=off` | `on` | Disables lowering client process priority below local localhost Factorio (`127.0.0.1`). |
| `--ups-overlay` | off | Shows the UPS governor diagnostics overlay in-game. |
| `--ups-probe=<out.json[@walk\|@governed=s]>` | off | Steps client distance/LOD knobs during a run to measure per-knob UPS gain. |
| `--update-check=off\|test` | button, no automatic check (Settings > Interface) | `off`: no "Check for updates" button and no request. `test`: the button and popup work with a made-up newer version, no request. |
| `--combat-shadows=off` | budgeted shadows (6) | Disables budgeted dual-paraboloid shadows on combat and turret `OmniLight3D`s (restores unshadowed combat lights). |
| `--fast-edit-coalesce=off` | 35 ms coalescing | Disables burst coalescing on repeated live edits to the same chunk in `world.gd`. |
| `--pipe-drag=line` | follows cursor | Holds dragged pipes (`pipe`, `heat-pipe`) to a straight line instead of following the cursor path round corners. |
| `--cursor-icon-world=old` | icon shown | Hides the held building's icon by the cursor over the world when a build ghost is visible. |
| `--tree-shadow-shape=old` | rounded polygons | Restores 2-triangle quad leaf-card shadows in `ModelLods.Job.crown_arrays`. |
| `--pipeline-joints=old` | hidden | Restores white/tinted joint chevron arrows on pipes and tanks in `PipelineMarks`. |
| `--auto-sort-open=old` | sorts while open | Waits until the character/machine window closes before auto-sorting main inventory. |
| `--belt-take-sync=old` | synced take/read | Restores pre-fix inserter-take vs belt-read/rescue synchronization in `BeltSim` / `BeltSimNative`. |
| `--inv-move-sfx=off` | UI item sounds | Disables inventory/slot/equipment move and pickup UI sounds. |
| `--inv-slot-flash=off` | orange flash | Disables the 1 s orange highlight on newly added inventory stacks. |
| `--item-picker-tabs=off` | tabbed picker | Restores the flat ungrouped item picker grid instead of Factorio item-group tabs. |
| `--turret-ammo-guard=off` | guarded firing | Disables client guard against waking folded turrets on uncorroborated ammo drops (artillery, which never names a target, is never held back; the bridge's `turret_ammo_check` counts its shells, and vehicles' untargeted shots, only while one of its force's projectiles flies near it). |
| `--alt-pipe-range=old` | full loaded range | Restores the 2-chunk radius cap on Alt-mode pipeline marks. |
| `--alt-robot-items=off` | robot cargo shown | Hides Alt-mode carried-item icons on flying worker robots (`AltOverlay`). |
| `--robot-dock-anim=off` | hover + shrink dock | Disables the personal-roboport robot return hover and shrink-into-back docking animation in `Movers`. |
| `--robot-charge-sparks=off` | charging sparks | Disables electric arc and spark effects on charging worker robots (`RobotSwarm`, `Movers`). |
| `--inserter-lod-scale=old` | scaled untextured | Stops applying `High`/`Ultra` LOD distance scaling to untextured models. |
| `--inserter-far-keep=off` | kept on High/Ultra | Allows `FarChunks` to merge inserter bases into static voxel meshes on `High`/`Ultra`. |
| `--inserter-shadows=old` | kept on High/Ultra | Drops inserter shadows outside `NEAR_SHADOW_RINGS` on `High`/`Ultra`. |
| `--inserter-rest-arms=box\|off` | 3D resting arms | `box` restores 3-`BoxMesh` stick resting arms; `off` hides resting inserter arms. |
| `--rest-arm-shadows=tier` | live | Resting inserter arms in far shadow-tier chunks cast no shadow on Low/Medium again (before 0.3.1); by default they cast as a live arm does. |
| `--rest-arm-basic=stick` | live | An inserter with no arm model rests as the thin 3-box stick without a shadow again (before 0.3.1); by default it rests as its live placeholder arm. |
| `--inserter-hand-stack=off` | stacked held items | Draws a single item per inserter hand instead of stacking up to 4 held items vertically. |
| `--mover-pick-3d=off` | 3D mover pick | Restores 3rd-person floor-entity priority over 3D vehicle/train bounding-box picking. |
| `--anim-sweep=old` | spread cleanup | Forgets the animator's states of entities gone in one frame every 5 s again (`anim.gd`, a 4-6 ms frame on a big base); by default the pass walks about 0.2 ms a frame until done. |
| `--signal-skip-same=off` | kept refresh | Walks every rail/chain signal at every 0.5 s glow refresh again (`signal_lights.gd`); by default a refresh whose inputs (reported states, signals added or gone, focus, darkness, camera, detail distance, hills, caps) are all as last time keeps its glows, with one in five done in full anyway. |
| `--mover-skip-still=off` | settled movers skipped | Works out every node mover (trains, cars) every frame again; by default one that stands still skips its position, rails, wheels, shadow and lift until a new position, rails changed under it (then awake for 121 frames, as world.gd may answer from its old rail grid that long), the headlights' beam or a model change. |
| `--native-rail-height=off` | native | Rolling stock finds the rails' height with world.gd's `rail_height` twice per mover in GDScript again; by default the bogie points of every moving train go to `MoversNative.rail_heights` in one call a frame, over its copy of each chunk's rail index (`--elevated-trains=old` always uses GDScript). It makes its own `MoversNative`, so `--native-movers=off` leaves it on: use this switch. |
| `--native-mover-sweep=off` | native | Simulated robots' grid sweep calls `MoverRecords.position` per robot again and robot batches rebuild their record list every frame; by default `MoversNative.positions` takes the sweep's 128 in one call, each batch keeps its record list, and the motion-vector idle check is one `MoversNative.any_active` call. |
| `--rail-signal-blocks=off` | outlines + blocks | Disables rail signal/train-stop placement tile outlines and signal-block overlays. |
| `--live-inserter-radius=view\|64` | detail | `view`: live inserter hands within the camera's view, up to 64 tiles (about 48 at the default zoom); `64`: within a fixed 64-tile square round the focus (0.3.1 before the view radius, Bug #5). The default `detail` is `f3d-detail-radius` alone (0.3.0). |
| `--rblk-anchors=off` | anchors | Rail block queries (`rblk`) without anchors: each query's ids as replied, so one block asked about in two queries can show as two colours. |
| `--near-tree-real-shadows=off` | real near shadows | Uses `ModelLods` stand-in hull shadows on near `SHADOWS_NEAR` tree chunks too. |
| `--pipe-cap-edge=old` | flush edge caps | Restores inset `cap_from` extraction without translating pipe caps flush to `z = -0.505`. |
| `--recipe-made-in=off` | machine icons | Restores crafting-category text (`Made in: ...`) instead of machine icon rows in recipe tooltips. |
| `--wet-metal=old` | damped wet metal | Restores the previous rain wetness on metallic models (no metallic dampening, lower wet roughness/pool/drip floors). |
| `--wet-rock=old` | current wet rock | Restores the older cliff and rock wetness appearance instead of matching rough stone. |
| `--organic-surface=old` | current organic surface | Disables procedural micro-bump, roughness breakup, and damp-organic rain wetness on creatures (chitin/flesh). |
| `--weather-timeline=<file>` | off | Replays scripted weather cue events from a JSON timeline file (for add-on testing). |

### Menu, Backdrop, Automation & Channels

| Switch | Default | Purpose |
|---|---|---|
| `--no-menu` | menu enabled | Skips the menu on startup and connects directly on `--factorio-port` (auto-enabled by in-game flags like `--open`, `--ui...`, `--camera`). |
| `--boot-screen=off` | boot screen on | Skips the staged startup boot/shader warmup screen and enters directly. |
| `--boot-skip=off` | Skip button on | Hides the boot screen's **Skip** button (shown beside Cancel while shaders/renderer warm; the first press warns about stutters with Wait (ETA) / Skip, the second starts the game and leaves the rest to compile while you play; the next start warms again). |
| `--shader-compile=safe\|fast\|old` | `safe` | Controls boot shader compilation pacing (`safe` caps cold concurrency to 1–2, serializes heavy shaders, keeps VSync + 30/15 FPS cap, and runs cold compile at below-normal process priority; `fast` / `old` restores uncapped aggressive compilation). |
| `--worker-threads=all\|<n>` | headroom cap | Caps `threading/worker_pool/max_threads` in `user://engine.cfg` (leaving cores free for the OS/DWM and other apps); `all` / `-1` restores Godot's uncapped `-1`. |
| `--shader-refresh=build\|off\|force` | `build` | Controls first-run shader cache refresh on new builds (`build` refreshes on a new build stamp; `off` skips; `force` refreshes this start). |
| `--dev-tools` | off | A public download with the testing tools a dev build has (the performance test, the debug menu; the update check stays off, as in a dev build). |
| `--shader-refresh-parent=wait` | exit | After a new build's shader refresh restart, the first process stays hidden and waits for the restarted one (ending with its exit code) instead of ending at once; for launchers that follow the first process id. The waiting window could stay visible, frozen on Godot's start screen. |
| `--dlc-detect=off` | on | Wube's DLC mods (Space Age, Quality, Elevated Rails, recycler) count as on unless turned off, even when the Factorio install has no such folder (before issue #28: a copy without Space Age couldn't make a new map). |
| `--create-console=off` | on | A failed map creation doesn't run Factorio once more to read the error it prints only to its console; the message shows the log's last lines only. |
| `--menu-backdrop-space=off` | on | A menu backdrop taken on a space platform shows the plain sky colour behind it, not space with the planet below. |
| `--menu-backdrop=default` | saved setting | Uses the built-in Space Age menu backdrop for this launch instead of the saved user snapshot. |
| `--menu-backdrop-camera=drift` | 3 deg sway | Restores the older drifting camera path over the main-menu backdrop. |
| `--menu-backdrop-save=overwrite` | keep list | Overwrites the current custom menu backdrop instead of appending timestamped entries in `user://backdrops/`. |
| `--backdrop-wait=off` | wait for 5x5 chunks | Allows Esc menu backdrop recording immediately instead of waiting for nearby chunks or 20 s. |
| `--menu-launch=<save>` | — | Auto-loads the named save through the menu launcher (equivalent to clicking Load). |
| `--menu-new=<name>[:<preset>[:<seed>]]` | — | Creates and starts a new map via the menu flow. |
| `--menu-host=<save>[:<port>]` | — | Hosts a saved game from the menu flow. |
| `--menu-connect=<host:port>` | — | Connects via the menu flow to a running bridge or relay. |
| `--connect-freeze=<s>` | — | Test: holds the main thread `<s>` seconds as a connect starts, to check the join wait (it counts only time the client ran, each frame's gap capped at 250 ms, so a stuck client no longer runs out the 30 s and stops the launched server). |
| `--menu-preview` | off | Requests Factorio's map preview when paired with `--menu=new`. |
| `--menu-save-after=<s>` / `--menu-save-as=<name>` | — | Automatically saves (or Saves As) after `<s>` seconds in-game (test/screenshot automation). |
| `--menu-exit-after=<s>` / `--menu-quit-after-exit` | — | Exits to the menu after `<s>` seconds, optionally quitting the client afterward. |
| `--factorio-config=<file>` | auto `config.ini` | Reads Factorio defaults from an explicit `config.ini` even when `--settings-file` is set. |
| `--factorio-player=<name>` | `player-data.json` username | Overrides the Factorio username (`pn`) sent in `hello` for player character handoff (`""` for none). |
| `--load-mods=save` | merge Mods list | Loads saves strictly with the save's own mods, ignoring the menu Mods window toggles. |
| `--saves-dir=<dir>` / `--server-data=<dir>` | default dirs | Isolates saves and server write-data into test directories. |
| `--port-base=<port>` | `34500` | Base port for menu-launched headless servers (UDP, game, RCON, client). |
| `--public-build` | channel dependent | Simulates a public release build from source (hides `Settings.dev_tools()` UI such as Debug menu & Perf test). |
| `--perf-test` | off | Launches straight into the main menu Performance test (dev builds / source only). |

### Factorio Server, Relay & Mock Server

- **Factorio flags:** `--enable-lua-udp <port>` (opens Factorio Lua UDP socket, default `34200`), `--create <save>` / `--start-server <save>` (headless create/host), `--generate-map-preview` (menu map preview), `--mp-connect <addr>` (used by `Ctrl+F9` to join Zenith's headless server from Factorio).
- **Client relay / connection flags:** `--factorio-host=<ip>` (`127.0.0.1` default; non-local addresses route through TCP relay), `--client-port=<port>` (live/client UDP port), `--relay` (forces TCP relay framing even against `127.0.0.1`).
- **`server/relay.py` flags:** `--port` (TCP port, default `34200`), `--host` (bind address, e.g. `::` for IPv6), `--bridge-port` (local Factorio UDP port, `34200`), `--allow <cidr|lan|any>` (default LAN/local ranges only; never `--allow any` on public interfaces), `--rcon-port <port>` (`34198` to forward RCON over TCP), `--max-clients` (`8`), `--timeout` (`30` s idle close), `--keep` (`30` s UDP port reservation for reconnects), `--max-buffer` (`8 MB` per-client send queue cap before drop), `--log <FILE>`, and `-v`; `tools/relay_check.py --reconnect` tests reconnect handoff.
- **`tools/mock_server.py` flags:** `--day-length <ticks>` (e.g. `1200` for a 20 s day), `--start <x,y>`, `--belt-field <WxH>`, `--belts-off <N> --belt-tiers`, `--item-showcase`, `--turrets`, `--planet <vulcanus|fulgora|gleba|aquilo>`, `--platform`, `--auto-launch`; paired with client flags `--plat-board=<id>@<s>`, `--ride=<id>@<s>`, `--land=<s>`.

### Packaging (`tools/release/package.py`)

- `--channel public|dev`: `public` (default) strips dev tools and `<!-- dev -->` doc sections; `dev` injects Godot feature tag `zenith_dev` and builds `Zenith-<version>-dev-<platform>.zip`.
- `--models <folder> --zenith-zip <out.zip>` (legacy alias `--default-zip`): Packages modeller `.glb`/`.gltf` assets into `models/Zenith.zip` (also bundles it when passed alongside normal `package.py` exports).

