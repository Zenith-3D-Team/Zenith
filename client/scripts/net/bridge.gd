extends Node
## UDP link to the factorio-3d-bridge mod (autoload "Bridge"). See docs/PROTOCOL.md.
##
## Reliable messages carry a sequence number `r`. On a gap we ask the mod to resend the chunks
## the world mirror knows are incomplete, or the whole handshake if the gap hit the prototype
## dictionaries.
##
## Nothing is sent until `connect_to` (the menu, or main.gd straight away when started with
## --factorio-port / --port); `disconnect_from` says goodbye and closes the socket.
##
## A bridge on another PC is reached through a relay beside it (server/relay.py, over TCP): see
## "A server on another PC" below.
##
## Command-line options (after `--`): --factorio-port=34200 --port=34201 --update-rate=0..3
## --factorio-host=<host> (a server on another PC, through its relay) --relay (the relay even on this PC)

const Switches := preload("res://scripts/switches.gd")

signal welcomed(msg: Dictionary)
signal message_received(msg: Dictionary)
signal connection_lost
## A console command's answer (`cmdr`), as soon as its datagram is read: ahead of the messages
## waiting for their turn (_drain hands out a few milliseconds of them a frame, so at a low frame
## rate a busy base's messages queue up for seconds, and the debug menu and a screenshot's pause
## gave up on answers that had come). It is handled in its turn too: ui_model.gd answers each id once.
signal answer_read(msg: Dictionary)
## A Factorio mod's message for its add-on (`ext`, addon_game.gd): handed only to the add-ons, never
## to message_received.
signal ext_received(msg: Dictionary)
## A filmed scene's cue tick set from the game (remote.call("zenith", "set_cue", tick), the welcome's
## `cue` or a `cue` message), -1 when cleared: api.world.cue_tick() reads cue_tick.
signal cue_changed(tick: int)

const PROTOCOL := 1
const HELLO_INTERVAL := 1.0
const TIMEOUT_MSEC := 5000
# A little over the mod's 120-tick limit, so a full resync is never dropped for arriving early.
const FULL_RESYNC_COOLDOWN_MSEC := 2500
# Chunk resyncs aren't limited by the mod; this only stops one per gap during a burst.
const CHUNK_RESYNC_COOLDOWN_MSEC := 500
const RECEIVE_BUFFER := 4 * 1024 * 1024
# Prototypes still incomplete and nothing reliable for this long: the end of the handshake was
# lost, and with nothing after it there is no gap to notice, so start it over.
const HANDSHAKE_STALL_MSEC := 3000
## (resync_guard) Full resyncs asked one after another without the world ever becoming ready wait
## longer each time: FULL_RESYNC_COOLDOWN_MSEC doubled per one, up to this.
const FULL_RESYNC_MAX_MSEC := 30000
## (resync_guard) The I/O thread says the last hello again when the main thread hasn't for this long
## (a frame of seconds: the first frame's pipelines on a slow GPU). The bridge drops a client after
## 600 ticks (10 s) without a hello and starts the handshake over at its next one (session.lua).
const KEEPALIVE_MSEC := 2000

var factorio_host := "127.0.0.1"
var factorio_port := 34200
var listen_port := 34201
## Ports after listen_port to try when it is taken (another client on this machine).
const MORE_PORTS := 7
## Ask for decoratives in the hello (main.gd, from the Graphics settings).
var decoratives := true
## How far (tiles) decoratives are drawn (main.gd, Graphics > Decorative distance): the hello's `dd`, so the
## bridge sends a chunk's decoratives only within it (and a margin), the rest as the view comes near. 0: not said.
var decorative_distance := 0
## Ask for mods' windows in the hello (main.gd, from the Interface settings).
var mod_windows := false
## The account this PC's Factorio plays under (main.gd, Paths.factorio_player_name), "" unknown: the
## hello's `pn`, so the player who joins with it takes over this client's character (L13).
var factorio_player := ""
## Ask for inserter events (`ie`) in the hello (main.gd, from inserter_arms.gd's flags): 0 no, 1
## instead of the samples, 2 as well as them.
var inserter_events := 0
var inserter_handoff := false  # (hello ho: the items inserters put on belts, inserter_arms.gd handoff)
## Binary frames (hello `bin`, wire_decode.gd): the busiest updates as numbers instead of JSON text, which
## the mod writes far faster. `--binary-messages=off`: the hello leaves `bin` out and everything comes as JSON.
var binary_messages := true
## --robot-sim=on|off (on): simulate worker robot flight on client/GPU (`rb`), or use legacy `mv`.
var robot_sim := true
var bind_error := OK
## True between a welcome and a timeout.
var connected := false
## True once the prototype dictionaries are complete ("ready" arrived).
var world_ready := false
## The bridge mod's version from the last welcome ("" before one): a bug report lists it.
var mod_version := ""
## The save's name from the last welcome (`sid`; "" from a bridge without one): what the client
## keeps per save, the look-only turns of buildings (visual_turns.gd, I9).
var save_id := ""
## The furthest square subscription the bridge takes (welcome `sq`, chunks; world.gd's `sub`); 0: a
## bridge from before them, which takes a list of at most 625 chunks.
var square_subs := 0
## The add-on link's version from the last welcome (`ext`; 0: the bridge carries no add-on messages).
var link_version := 0
## The cue set from the game (`cue`, link.lua set_cue): -1 none.
var cue_tick := -1
## Whether the bridge mod supports distant horizon `lod_sub` streams (`lod` in `welcome`).
var lod_supported := false
## `--distant-horizon=off` (`=0` / `=false`) stops the handshake from asking for `lod_sub` streams.
var distant_horizon_enabled := _distant_horizon_arg()


static func _distant_horizon_arg() -> bool:
	for arg: String in Switches.args():
		if arg.begins_with("--distant-horizon="):
			var v := arg.get_slice("=", 1).to_lower()
			if v == "off" or v == "0" or v == "false":
				return false
	return true
## The tick of the message handled last: what the world mirror has reached.
var server_tick := 0
## The newest tick read off the socket: where the game is now. server_tick runs behind it while
## messages wait their turn (_drain) and catches up in bursts, so the game's UPS is measured on this
## (a busy base at 6 fps read 161 UPS at game speed 1 on server_tick).
var newest_tick := 0
var stats := {"packets": 0, "bytes": 0, "gaps": 0, "handle_usec": 0, "resyncs": 0, "full_resyncs": 0, "bad_json": 0, "bad_frames": 0, "prio_sent": 0, "me_first": 0, "prio_first": 0, "live_first": 0, "coalesced": 0, "nacks_sent": 0, "nack_hits": 0, "nack_timeouts": 0, "nack_late_drops": 0}
## Datagram loss, from the bridge's numbering (its `dg` line at the end of each datagram, asked for
## with `dq` in the hello): "datagrams" numbered ones read, "lost" the numbers skipped (datagrams the
## OS dropped: Windows keeps 64 KB of unread datagrams per socket), "unnumbered" datagrams without
## the line (a bridge from before it, or a datagram too full for it).
var loss := {"datagrams": 0, "lost": 0, "unnumbered": 0}
var _dg_expected := -1
## --udp-trace=<file>: a line per datagram read, as JSON: {"us": when the I/O thread read it
## (Time.get_ticks_usec), "n": its number (-1 unnumbered), "b": bytes, "k": its tick, "m": {type:
## count}} (tools/udp_loss_check.py reads it beside the bridge's log).
var _udp_trace: FileAccess = null
## The bridge's last `wb`: its work budget per tick (`b`, in work units), the units it used per tick
## over the last second (`avg`, `max`), ticks over budget (`over`) and its queues' lengths (`q`).
var work_budget := {}
## When it came (Time.get_ticks_msec), 0 before the first.
var work_budget_msec := 0
## Main-thread time spent on each message type so far, in microseconds (for perf probes).
var handle_usec := {}
var last_reliable_msec := 0
## Returns the chunks to ask for again after a gap, as [[cx, cy], ...]. Set by the world mirror.
var resync_chunks: Callable
## How much the mod slows its costliest updates down (`rate`, PROTOCOL.md): 0 normal to
## MAX_UPDATE_RATE. Set with set_update_rate; sent again after every handshake.
var update_rate := 0
const MAX_UPDATE_RATE := 3
var _rate_sent := -1
## Alt-mode is on, for the chests' contents (`altc`, J6): the count of its turnings on, which each
## `ac` carries back (world.gd keeps only the current turning's), or 0 while off. Set with
## set_alt_contents; said again after every handshake, which turns it off in the bridge.
var alt_contents := 0
## --loco-fuel-icons=on: Alt-mode shows locomotives' fuel again (off by default; the cargo wagons' items show instead).
## Sent with `altc` as `lf`, so the bridge reads locomotives only then.
var loco_fuel_icons := Switches.has("--loco-fuel-icons=on")
var _alt_turns := 0
var _alt_sent := 0

## The UI test sets this to an array: what would be sent goes there as JSON instead.
var capture = null

var _udp := PacketPeerUDP.new()
## --udp-socket=native|godot: the socket the I/O thread reads. native (the default when the C++
## extension is loaded, client/native): UdpSocketNative, a socket whose OS receive buffer is
## --udp-rcvbuf=<bytes> (8 MB) and whose wait() wakes the thread as a datagram arrives. godot:
## PacketPeerUDP, whose OS buffer stays the OS default (Windows: 64 KB; its bind()'s size is only
## Godot's own ring): the bridge's tick bursts, several datagrams of up to 60 KB within a
## millisecond, overflowed it and a tick's tail was dropped (measured at -62,-26 as lost `bs` parts,
## 0.3-0.6% of them, and `ih` updates; tools/udp_loss_check.py), and OS.delay_usec(1000) sleeps
## 2 ms on Windows, so the drain between the burst's datagrams often came too late.
const NATIVE_SOCKET := "UdpSocketNative"
const NativeLibrary := preload("res://scripts/native_library.gd")
var udp_native := true
var udp_rcvbuf := 8 * 1024 * 1024
## --udp-io-priority=high|normal: the I/O thread's priority. Measured at -62,-26 (before the native
## socket, 8 minutes traced): the thread, at normal priority on this 4-core PC with the game, the belt
## jobs and the parsing thread beside it, went unscheduled 49 times for over 100 ms (up to 611 ms);
## each stall filled the 64 KB and lost every datagram until the next read (28 runs of 1-21 ticks'
## datagrams, 128 of 3897, 3.3%). High: Thread.PRIORITY_HIGH, so a datagram's arrival gets it the CPU.
var udp_io_high := true
## --message-catchup=on|off (on): while the oldest message waiting has waited longer than
## --message-catchup-msec=N (250) since its datagram was read, the messages get their own slice of
## the frame (frame_budget.gd's `messages`, 4 ms) whatever the shared pool has left. The pool sits at
## its 3 ms floor whenever the frame's other scripts take 9 ms or more (loading or walking a big base),
## which left the messages 2 ms a frame, backlog or not (the doubled slice past BACKLOG_MESSAGES is
## capped by the pool too). Since main's 0.2.0 work came in (68f61e5f) the frame at -62,-26 waits on
## the GPU (19-20 ms: ~41 fps instead of 48-54), and that was fewer messages a second than the bridge
## sends there while the client loads and stands: the queue grew through the whole warm-up to
## 4,300-4,700 waiting (15-27 s behind) and every chunk asked for while walking was answered behind it
## (belt_walk_check at -62,-26: chunks wanted to drawn p50 31-144 s, 107-164 never drawn, belts 54-76%
## visible; with this, 1.5-2.2 s, 0-13 and 99%: docs/RUNNING.md). off: as before.
var message_catchup := true
var catchup_usec := 250000
## --replay-kinds=on|off (on): a kept message handed again (Replay, world.gd's kept chunks) carries its message type,
## so the messages' slice guesses its cost by that type (FrameBudget.item_est `replay:<t>`: a kept chunk's `ents`
## costs far more than its `cq`) and --stutter-probe names it (`replay:<t>`). off: one `replay` estimate for all of
## them, as before. The order messages are handled in is the same either way.
var replay_kinds := true
## --drain-head-again=on|off (on, perf-w4-fix S3): when a message in the messages' slice puts entries in front
## (requeue_front: a live `ents` message's slices) and time is left, the slice runs them this frame. off: the
## slice stopped at them and they waited for the next frame, as before.
var drain_head_again := true
## --resync-guard=on|off (on): a full resync can't loop. The handshake's stall check (HANDSHAKE_STALL_MSEC)
## asked for a full resync whenever `ready` had not been *handled* 3 s after the last reliable message was
## *read*; a full resync restarts the bridge's handshake (session.lua: the world cleared, lod.reset), and
## the bridge then sends nothing reliable until the client subscribes, which it does only once `ready` is
## handled. So a client whose messages were more than 3 s behind as the handshake ended (a slow PC: the
## first frames' pipelines, the welcome's 74 ms, 4 cores) asked again every ~3 s for good, each resync
## refilling the queue with a new handshake and Distant Horizon's macro chunks: the second PC's warm starts
## (7-10 resyncs, 7,000-9,000 messages waiting, no chunk drawn). With the guard: `ready` read and waiting
## its turn counts (it isn't lost); a full resync isn't asked again while the last one's welcome waits in
## the queue, and those asked without the world becoming ready in between back off (2.5, 5, 10, 20, 30 s);
## the messages read before a new session's welcome are dropped, not handled (the old session's, which
## the new one replaces); and while `ready` waits in the queue the messages get the catch-up slice.
## The hellos too: Godot caps _process's delta at about 0.13 s (8 physics steps), so the hello timer,
## which added up delta, sent one every 8 frames on frames slower than that: under 1 FPS none for 10 s,
## and the bridge dropped the client and started the handshake over at the next one (measured: 3.5 s
## frames, a handshake every 14.5 s, nothing ever drawn). With the guard a hello goes by the clock,
## the I/O thread says the last one again when a frame takes seconds (KEEPALIVE_MSEC), and a hello
## says the welcome came (`w`) once it is read, not only once it is handled.
## off: as before.
var resync_guard := true
## --belt-messages-first=on|off (on; the owner: belt logic is the last thing culled for performance): the belt
## simulation's updates (`bs`) are handled as they are read, before the other messages waiting, outside the
## messages' slice of the frame (handing one to belt_items.gd costs a few µs: it queues it for the belt job).
## Behind a `welcome` or `surface` still waiting (both start the belts over) and behind belt messages already
## queued after one, they keep their place. Off: in the one queue with everything else, as before: under a
## backlog (a hitch, a burst of chunks and decoratives) the belts' updates waited behind it and the belts were
## drawn from updates seconds old. The inserters' events (`ie`) stay in order: ahead of the `add` of an inserter
## built during a backlog they made an arm with no entity (drawn at the map's origin for half a second, then its
## first swings a tile or two off: a fresh map, 4,000 walls built at once, 650 ms hitches).
var belt_messages_first := true
const BELT_MESSAGES := {"bs": true}
## Messages waiting in _waiting that start the belts over, and belt messages waiting there behind one.
const BELT_BARRIERS := {"welcome": true, "surface": true}
var _belt_barriers := 0
var _belts_behind := 0
## Belt messages read and not handled yet (belt_messages_first), oldest first.
var _belt_waiting: Array = []
## --priority-queue=off: restores single FIFO send/drain instead of priority movement (`me`) & player actions.
var priority_queue := true
## --coalesce-updates=off: disables live fast-lane routing and snapshot coalescing.
var coalesce_updates := true
## --nack=off: disables selective NACK recovery on reliable packet gaps.
var nack_enabled := true
## --reliable-reorder=off: reliable messages after a NACKed gap are handled at once (before the
## retransmits that fill it), as before. On: they wait in _reorder until the gap fills, then go in
## order (a `chunk` header retransmitted after its `ents` no longer empties the chunk). Needs the
## priority queue (its sequence check runs as messages arrive); the NACK timeout still resyncs.
var reliable_reorder := true
## --prio-delta-order=off: a chunk's `add`/`upd`/`del` may take the priority lane while an older one
## for the same chunk still waits in bulk _waiting (a `del` handled before its `add`), as before.
var prio_delta_order := true
const PRIORITY_COMMANDS := {
	"walk": true, "drive": true, "enter": true, "mine": true, "mine_stop": true, "mine_at": true,
	"build": true, "blueprint": true, "rails": true, "tile": true, "tile_mine": true, "rotate": true, "flip": true,
	"open": true, "close": true, "pick": true, "take": true, "put": true, "move": true, "xfer": true, "fast": true,
	"sort": true, "inv_filter": true, "drop": true, "pickup": true, "pickup_stop": true,
	"shoot": true, "gun": true, "throw": true, "craft": true, "cancel_craft": true,
	"wire": true, "wire_clear": true, "decon": true, "upgrade": true,
	"copy": true, "paste": true, "paste_settings": true, "undo": true, "redo": true,
	"qb_set": true, "qb_sel": true, "qb_page": true,
	"set_recipe": true, "set_bar": true, "set_inserter": true, "set_splitter": true, "set_switch": true,
	"set_panel": true, "set_cb": true, "set_cc": true, "set_color": true, "set_lamp": true,
	"set_desc": true, "set_speaker": true, "set_pump": true, "set_targets": true, "set_vehicle": true,
	"set_artillery": true, "set_requests": true, "set_storage_filter": true, "set_chest_logistics": true,
	"set_char_requests": true, "set_section": true, "set_schedule": true, "set_char_color": true,
	"set_lnet_name": true, "lnet_find": true,
	"train_go": true, "train_mode": true, "train_mode_id": true, "train_temp": true,
	"set_stop": true, "set_interrupts": true, "set_train_group": true,
	"eq_put": true, "eq_take": true, "eq_move": true, "eq_toggle": true,
	"repair": true, "pause": true, "focus": true, "sub": true, "bre": true, "nack": true,
	"modreq": true, "unghost": true, "respawn": true, "flush": true, "spider_go": true,
	"set_hub": true, "set_pad": true, "set_silo": true, "silo_launch": true, "set_collector": true,
	"ride": true, "land": true, "plat_board": true, "plat_pause": true, "plat_go": true, "plat_sched": true,
	"view": true, "research": true, "research_cancel": true, "bp_page": true, "bp_del": true, "bp_set": true,
	"tag_add": true, "tag_del": true, "mpress": true, "mset": true,
}
const ME_MESSAGES := {"me": true}
const PRIO_MESSAGES := {
	"gui": true, "slots": true, "inv": true, "qb": true, "cq": true, "mnd": true, "pku": true, "msg": true,
	"shot": true, "guns": true, "bp_ok": true, "clip": true, "eq": true, "hist": true, "craftable": true, "cmdr": true,
}
const LIVE_FAST_MESSAGES := {"ie": true, "mv": true, "rb": true, "pj": true, "afx": true, "hp": true}
const SINGLE_SNAPSHOT_MESSAGES := {"cq": true, "al": true, "sky": true}
const MULTI_SNAPSHOT_MESSAGES := {"mv": true, "ih": true, "gi": true, "en": true, "hp": true}
const CHUNK_DELTA_MESSAGES := {"add": true, "upd": true, "del": true}
const PRIO_BARRIERS := {"welcome": true, "ready": true, "surface": true}
const NACK_TIMEOUT_MSEC := 250
const NACK_MAX_GAP := 64
const NACK_EXPIRED_GRACE_MSEC := 2500
var _me_waiting: Array = []
var _prio_waiting: Array = []
var _live_waiting: Array = []
var _replay_head: Array = []
var _replay_at := 0
var _prio_barriers := 0
var _chunk_waiting := {}  # Vector2i -> pending chunk/ents count in _waiting
var _nack_pending := {}  # int r -> int sent_msec
var _nack_expired := {}  # int r -> int expired_msec
## (reliable_reorder) Reliable messages after a gap: int r -> [message, length, read usec], until the gap fills.
var _reorder := {}
## The highest r held in _reorder (0 when empty), and when the first one was held (msec).
var _reorder_high := 0
var _reorder_since := 0
## r values handed on past a gap given up on (flushed): the sequence check moves past them quietly.
var _reorder_gap_ok := {}
## At most this many held, and for at most this long, before giving up on the gap (resync, as before).
const REORDER_MAX := 4096
const REORDER_MAX_MSEC := 1000
var _seq_connected := false
var _seq_world_ready := false
## The native socket while in use (then _udp is left unbound); null with PacketPeerUDP.
var _nudp: RefCounted = null
## What the socket is, for the status line and probes ("" before connect_to).
var socket_kind := ""
## The socket is read on a thread of its own. Windows keeps only ~64 KB of unread datagrams per
## socket, which the mod's chunk stream fills in a couple of ticks: read only between frames, any
## frame over ~30 ms (a terrain texture loading, a burst of chunk builds) lost chunks, and their
## ground stayed missing until a resync. While the thread runs only it touches the socket: sends queue.
var _io_thread: Thread
var _io_mutex := Mutex.new()
var _send_mutex := Mutex.new()
var _io_run := false
var _inbox: Array[PackedByteArray] = []
## When each of _inbox's datagrams was read (Time.get_ticks_usec), for --udp-trace.
var _inbox_usec := PackedInt64Array()
var _outbox: Array[PackedByteArray] = []
var _outbox_prio: Array[PackedByteArray] = []
## The datagrams' JSON is read on a thread of its own too (walking a big base, decoding was about
## half of the 2-7 ms a frame spent on messages): the I/O thread hands it what it read (_inbox),
## it hands the main thread the messages read (_parsed: [datagram bytes, messages, their lengths,
## how many had numbers that aren't finite, the newest tick, the console answers (`cmdr`), the `dg`
## number, when it was read, the types traced, 1 for a bad binary frame]), and
## the main thread only handles them. A thread of
## its own, not the I/O thread's: reading a burst's JSON there would leave the socket unread for
## tens of milliseconds. Its own JSON and RegEx: neither is shared between threads.
var _parse_thread: Thread
var _parse_sem := Semaphore.new()
var _parsed: Array = []
var _session := ""
var _expected_r := 1
var _hello_timer := 0.0
var _hello_msec := -100000  # (resync_guard) the last hello, by the clock
## (resync_guard, under _io_mutex) The last hello said after the welcome, and when a hello last went:
## the I/O thread sends it again past KEEPALIVE_MSEC.
var _keepalive := PackedByteArray()
var _keepalive_msec := 0
var _last_packet_msec := 0  # the last message handled
var _last_read_msec := 0  # the last datagram read
## Reasons the game was paused on purpose (a screenshot's pause): a tick-paused game runs no on_tick,
## so the bridge sends nothing until it resumes, and that silence isn't a lost connection.
var _quiet_by := {}
var _last_resync_msec := -100000
## 0 none, 1 chunks, 2 full. Sent after the frame's packets are handled, so the chunk list
## sees what arrived after the gap, and kept through the cooldown, so packets lost in the middle
## of a resend burst are still asked for.
var _pending_resync := 0
## (resync_guard) Full resyncs sent since `ready` was last handled; one sent whose welcome hasn't
## been handled yet, and whether that welcome has been read (it then waits in the queue).
var _full_streak := 0
var _full_wait := false
var _full_welcome_read := false
## (resync_guard) This session's welcome read (the hello's `w`): cleared with `connected` by the timeout and a
## disconnect, so the hello asks for the welcome again.
var _welcome_read := false
## (resync_guard) _waiting's messages before this index were read before a new session's welcome:
## dropped by _drain, not handled.
var _stale_until := 0
## Messages dropped that way, so far (tests, the F4 line's stats).
var stale_dropped := 0
## Hellos the I/O thread said again during long frames, so far.
var keepalives := 0

## A server on another PC (docs/RUNNING.md, "Server on another PC"). Factorio's Lua UDP reaches only
## 127.0.0.1, so a relay beside the server (server/relay.py) carries the bridge's datagrams over TCP,
## each as a frame: 4 bytes of length (big-endian), then the datagram as it was; commands go back the
## same way (docs/PROTOCOL.md, "Over the network"). TCP, not UDP: the bridge's datagrams are up to 60 KB,
## some 40 IP fragments each across a network, and a lost fragment loses the whole datagram. The client
## says RELAY_GAME first; the relay answers the same, or RELAY_REFUSED and a frame saying why. Everything
## above the transport (hello, sequencing, resyncs) is as over UDP. A dropped connection is made again
## (at once, then every RELAY_RETRY_MSEC), the last hello first: the relay finds the session's port to
## the bridge by its sid and gives it back, so the bridge sees nothing change.
const RELAY_GAME := "ZRL1"
const RELAY_REFUSED := "ZRL!"
const RELAY_RETRY_MSEC := 2000
const RELAY_BACK_MSEC := 250
const RELAY_CONNECT_MSEC := 5000
const RELAY_MAX_FRAME := 1 << 20
## Addresses of this PC: the bridge is reached over UDP. Any other host is a server on another PC.
const THIS_PC := ["127.0.0.1", "localhost", "::1"]
## --relay: through a relay even at an address on this PC (tests, trying the relay on one PC).
var relay_forced := false
## True while connected through a relay (connect_to decides).
var via_relay := false
var _relay: StreamPeerTCP = null
var _relay_open := false  # between connect_to and disconnect_from
var _relay_in := PackedByteArray()
var _relay_out := PackedByteArray()
var _relay_greeted := false
var _relay_tuned := false
var _relay_started := 0
var _relay_retry_at := 0
## The last hello sent: the first frame on every new connection, so the relay picks the session's port.
var _relay_hello := PackedByteArray()
## What the relay link is doing, for the connecting screen and the status line (relay_status()).
var _relay_state := ""


func _ready() -> void:
	NativeLibrary.ensure()  # early, on the main thread, for whatever looks for its classes later
	for arg in Switches.args():
		if arg.begins_with("--factorio-port="):
			factorio_port = int(arg.get_slice("=", 1))
		elif arg.begins_with("--factorio-host="):
			factorio_host = arg.get_slice("=", 1).strip_edges()
		elif arg == "--relay":
			relay_forced = true
		elif arg.begins_with("--port="):
			listen_port = int(arg.get_slice("=", 1))
		elif arg.begins_with("--update-rate="):
			set_update_rate(int(arg.get_slice("=", 1)))
		elif arg.begins_with("--udp-trace="):
			_udp_trace = FileAccess.open(arg.get_slice("=", 1), FileAccess.WRITE)
			if _udp_trace == null:
				push_warning("bridge: can't write the UDP trace %s" % arg.get_slice("=", 1))
		elif arg.begins_with("--udp-socket="):
			udp_native = arg.get_slice("=", 1) != "godot"
		elif arg.begins_with("--udp-rcvbuf="):
			udp_rcvbuf = maxi(65536, int(arg.get_slice("=", 1)))
		elif arg.begins_with("--udp-io-priority="):
			udp_io_high = arg.get_slice("=", 1) == "high"
		elif arg.begins_with("--message-catchup="):
			message_catchup = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--replay-kinds="):
			replay_kinds = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--drain-head-again="):
			drain_head_again = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--resync-guard="):
			resync_guard = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--message-catchup-msec="):
			catchup_usec = maxi(0, int(arg.get_slice("=", 1))) * 1000
		elif arg.begins_with("--belt-messages-first="):
			belt_messages_first = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--priority-queue="):
			priority_queue = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--coalesce-updates="):
			coalesce_updates = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--nack="):
			nack_enabled = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--reliable-reorder="):
			reliable_reorder = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--prio-delta-order="):
			prio_delta_order = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--binary-messages="):
			binary_messages = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--robot-sim="):
			robot_sim = arg.get_slice("=", 1) != "off"
	randomize()


## Binds the socket to 127.0.0.1:port (0: any free one): the native one when asked for and loaded,
## else PacketPeerUDP. Returns the bind's error.
func _sock_bind(port: int) -> Error:
	_nudp = null
	if udp_native and NativeLibrary.ensure() and ClassDB.class_exists(NATIVE_SOCKET):
		var sock: RefCounted = ClassDB.instantiate(NATIVE_SOCKET)
		var err := sock.bind(port, "127.0.0.1", udp_rcvbuf) as Error
		if err == OK:
			_nudp = sock
			socket_kind = "native, %d KB receive buffer" % (int(sock.receive_buffer_size()) / 1024)
			return OK
		if err == ERR_ALREADY_IN_USE:
			return err
		push_warning("bridge: the native UDP socket couldn't bind (error %d, OS %d): using PacketPeerUDP" % [err, int(sock.last_error())])
	_udp = PacketPeerUDP.new()
	var err := _udp.bind(port, "127.0.0.1", RECEIVE_BUFFER)
	if err == OK:
		socket_kind = "PacketPeerUDP (the OS's default receive buffer)"
	return err


func _sock_bound() -> bool:
	if via_relay:
		return _relay_open
	return _nudp.is_bound() if _nudp != null else _udp.is_bound()


## The port the socket listens on (tests bind to 0: any free one); 0 through a relay.
func local_port() -> int:
	if via_relay:
		return 0
	return int(_nudp.get_local_port()) if _nudp != null else _udp.get_local_port()


func _sock_put(data: PackedByteArray) -> void:
	_send_mutex.lock()
	if via_relay:
		_relay_put(data)
	elif _nudp != null:
		_nudp.put_packet(data)
	else:
		_udp.put_packet(data)
	_send_mutex.unlock()


func _sock_close() -> void:
	_send_mutex.lock()
	if via_relay:
		_relay_close()
	elif _nudp != null:
		_nudp.close()
		_nudp = null
	elif _udp.is_bound():
		_udp.close()
	_send_mutex.unlock()


## Asks the mod to send its costliest updates less often (0 normal, 1-3 slower and slower): when
## the server is under load the world may lag, but the server won't. Belt items, movers and
## inserter hands still glide (their messages say how far apart they are); the character's own
## updates never slow down.
func set_update_rate(level: int) -> void:
	update_rate = clampi(level, 0, MAX_UPDATE_RATE)


## Starts talking to the mod at host:port from our UDP port `listen`. bind_error says if the
## port couldn't be opened.
func connect_to(host: String, port: int, listen: int) -> void:
	disconnect_from()
	factorio_host = host
	factorio_port = port
	listen_port = listen
	_session = "%d-%d" % [int(Time.get_unix_time_from_system()), randi() % 1000000]
	via_relay = through_relay(host)
	if via_relay:
		# Nothing to bind: the I/O thread connects to the relay (and again whenever the link drops).
		listen_port = 0
		_relay_open = true
		_relay = null
		_relay_retry_at = 0
		_set_relay_state("connecting")
		socket_kind = "relay at %s:%d (TCP)" % [host, port]
		_start_io()
		return
	bind_error = _sock_bind(listen_port)
	# Another client on this machine has the port: a server takes up to 8 clients, each on its own
	# port, so try the next ones.
	var tries := 0
	while bind_error != OK and listen_port != 0 and tries < MORE_PORTS:
		tries += 1
		bind_error = _sock_bind(listen + tries)
		if bind_error == OK:
			listen_port = listen + tries
	if bind_error != OK:
		push_error("Can't listen on UDP port %d (error %d). Is another client running?" % [listen_port, bind_error])
		return
	if _nudp != null:
		_nudp.set_dest_address(host, factorio_port)
	else:
		_udp.set_dest_address(host, factorio_port)
	_start_io()


## Whether `host` is this PC, where the bridge's own UDP port is reached directly.
static func is_this_pc(host: String) -> bool:
	return host.strip_edges().to_lower() in THIS_PC or host.begins_with("127.")


## Whether connect_to(host, ...) goes through a relay: a host other than this PC, or --relay.
func through_relay(host: String) -> bool:
	return relay_forced or not is_this_pc(host)


## Whether the server (Factorio and the bridge) runs on this PC: things that need its window, its
## files or its process (Ctrl+F9's swap, the menu's server, the CPU priority) work only then.
func server_on_this_pc() -> bool:
	return is_this_pc(factorio_host)


## What the relay link is doing ("" when not through a relay): "connecting", "connected", "refused: ..."
## or "lost: ...". Set on the I/O thread.
func relay_status() -> String:
	_io_mutex.lock()
	var s := _relay_state
	_io_mutex.unlock()
	return s


func _set_relay_state(s: String) -> void:
	_io_mutex.lock()
	var changed := s != _relay_state
	_relay_state = s
	_io_mutex.unlock()
	if changed and s != "connecting":
		print("bridge: relay at %s:%d %s" % [factorio_host, factorio_port, s])


func _start_io() -> void:
	_io_run = true
	_io_thread = Thread.new()
	_io_thread.start(_io_loop, Thread.PRIORITY_HIGH if udp_io_high else Thread.PRIORITY_NORMAL)
	_parse_thread = Thread.new()
	_parse_thread.start(_parse_loop)
	# The first hello waits for the first frame. Sent now, the mod's ~200 KB handshake would
	# arrive while the main scene is still loading, and Windows keeps only ~64 KB of unread
	# datagrams per socket.
	_hello_timer = HELLO_INTERVAL
	_hello_msec = -100000


## Says goodbye and closes the socket; nothing more arrives until the next connect_to.
func disconnect_from() -> void:
	_stop_io()
	if _sock_bound():
		send({"t": "bye"})
		_sock_close()
	via_relay = false
	_relay_hello = PackedByteArray()
	_relay_state = ""
	connected = false
	world_ready = false
	link_version = 0
	cue_tick = -1
	lod_supported = false
	bind_error = OK
	server_tick = 0
	newest_tick = 0
	_io_mutex.lock()
	_outbox.clear()
	_outbox_prio.clear()
	_io_mutex.unlock()
	stats = {"packets": 0, "bytes": 0, "gaps": 0, "handle_usec": 0, "resyncs": 0, "full_resyncs": 0, "bad_json": 0, "bad_frames": 0, "prio_sent": 0, "me_first": 0, "prio_first": 0, "live_first": 0, "coalesced": 0, "nacks_sent": 0, "nack_hits": 0, "nack_timeouts": 0, "nack_late_drops": 0}
	loss = {"datagrams": 0, "lost": 0, "unnumbered": 0}
	_dg_expected = -1
	_waiting.clear()
	_waiting_len.clear()
	_waiting_usec.clear()
	_waiting_checked.clear()
	_waiting_at = 0
	_belt_waiting.clear()
	_belt_barriers = 0
	_belts_behind = 0
	_me_waiting.clear()
	_prio_waiting.clear()
	_live_waiting.clear()
	_replay_head.clear()
	_replay_at = 0
	_prio_barriers = 0
	_chunk_waiting.clear()
	_nack_pending.clear()
	_nack_expired.clear()
	_reorder_clear()
	_seq_connected = false
	_seq_world_ready = false
	_expected_r = 1
	_pending_resync = 0
	_full_streak = 0
	_full_wait = false
	_full_welcome_read = false
	_welcome_read = false
	_stale_until = 0
	_last_packet_msec = 0
	_last_read_msec = 0
	last_reliable_msec = 0
	_quiet_by.clear()


## The I/O thread: sends what's queued (priority commands first), then reads everything waiting, about once a millisecond.
func _io_loop() -> void:
	while true:
		_io_mutex.lock()
		var run := _io_run
		var out_prio := _outbox_prio
		var out := _outbox
		_outbox_prio = []
		_outbox = []
		var again := PackedByteArray()
		if not _keepalive.is_empty() and Time.get_ticks_msec() - _keepalive_msec >= KEEPALIVE_MSEC:
			again = _keepalive  # the main thread is in a long frame: the bridge mustn't drop this client
			_keepalive_msec = Time.get_ticks_msec()
			keepalives += 1
		_io_mutex.unlock()
		for data in out_prio:
			_sock_put(data)
		for data in out:
			_sock_put(data)
		if not again.is_empty():
			_sock_put(again)
		if not run:
			return
		var got: Array[PackedByteArray] = []
		var when := PackedInt64Array()
		if via_relay:
			_relay_poll(got, when)
		elif _nudp != null:
			while true:
				var packet: PackedByteArray = _nudp.get_packet()
				if packet.is_empty():
					break
				got.append(packet)
				when.append(Time.get_ticks_usec())
		else:
			while _udp.get_available_packet_count() > 0:
				got.append(_udp.get_packet())
				when.append(Time.get_ticks_usec())
		if not got.is_empty():
			_io_mutex.lock()
			_inbox.append_array(got)
			_inbox_usec.append_array(when)
			_io_mutex.unlock()
			_parse_sem.post()
		if _nudp != null and not via_relay:
			_nudp.wait(1000)  # back as soon as a datagram comes, or in a millisecond for the sends
		else:
			OS.delay_usec(1000)  # (a relay's TCP keeps what comes meanwhile: nothing is lost waiting)


## The relay link, on the I/O thread: (re)connects, greets, writes what waits and reads whole frames
## into `got`. Over TCP nothing is lost while the thread waits; the relay holds a few MB for a
## Zenith that falls behind and then drops whole datagrams, which the sequencing asks for again.
func _relay_poll(got: Array[PackedByteArray], when: PackedInt64Array) -> void:
	var now := Time.get_ticks_msec()
	if _relay == null:
		if now < _relay_retry_at:
			return
		_relay = StreamPeerTCP.new()
		_relay_in = PackedByteArray()
		_relay_greeted = false
		_relay_tuned = false
		_relay_started = now
		var err := _relay.connect_to_host(factorio_host, factorio_port)
		if err != OK:
			_relay_lost("can't reach %s:%d (error %d)" % [factorio_host, factorio_port, err])
			return
		# Said first, so the relay knows this is Zenith; then the last hello, so it picks this session's port.
		_relay_out = RELAY_GAME.to_ascii_buffer()
		_io_mutex.lock()
		var last_hello := _relay_hello
		_io_mutex.unlock()
		if not last_hello.is_empty():
			_relay_out.append_array(_relay_frame(last_hello))
	_relay.poll()
	var status := _relay.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTING:
		if now - _relay_started > RELAY_CONNECT_MSEC:
			_relay_lost("no answer from %s:%d" % [factorio_host, factorio_port])
		return
	if status != StreamPeerTCP.STATUS_CONNECTED:
		_relay_lost("connection closed" if _relay_greeted else "can't connect to %s:%d" % [factorio_host, factorio_port])
		return
	if not _relay_tuned:
		_relay_tuned = true
		_relay.set_no_delay(true)  # commands are small: no waiting to fill a segment
	if not _relay_out.is_empty():
		var wrote: Array = _relay.put_partial_data(_relay_out)
		if int(wrote[0]) != OK:
			_relay_lost("write failed (error %d)" % int(wrote[0]))
			return
		if int(wrote[1]) > 0:
			_relay_out = _relay_out.slice(int(wrote[1]))
	var available := _relay.get_available_bytes()
	if available > 0:
		var read: Array = _relay.get_partial_data(available)
		if int(read[0]) != OK:
			_relay_lost("read failed (error %d)" % int(read[0]))
			return
		_relay_in.append_array(read[1])
	if _relay_in.is_empty():
		return
	var at := 0
	if not _relay_greeted:
		if _relay_in.size() < 4:
			return
		var said := _relay_in.slice(0, 4).get_string_from_ascii()
		if said == RELAY_REFUSED:
			if _relay_in.size() < 8 or _relay_in.size() < 8 + _frame_size(_relay_in, 4):
				return
			var why := _relay_in.slice(8, 8 + _frame_size(_relay_in, 4)).get_string_from_utf8()
			_relay_lost("refused: " + why, 5000)
			return
		if said != RELAY_GAME:
			_relay_lost("refused: %s:%d isn't a Zenith relay" % [factorio_host, factorio_port], 5000)
			return
		_relay_greeted = true
		at = 4
		_set_relay_state("connected")
	while _relay_in.size() - at >= 4:
		var size := _frame_size(_relay_in, at)
		if size > RELAY_MAX_FRAME:
			_relay_lost("a frame of %d bytes: not a Zenith relay" % size)
			return
		if _relay_in.size() - at - 4 < size:
			break
		if size > 0:
			got.append(_relay_in.slice(at + 4, at + 4 + size))
			when.append(Time.get_ticks_usec())
		at += 4 + size
	if at > 0:
		_relay_in = _relay_in.slice(at)


## The big-endian length at `at`.
static func _frame_size(buf: PackedByteArray, at: int) -> int:
	return (buf[at] << 24) | (buf[at + 1] << 16) | (buf[at + 2] << 8) | buf[at + 3]


static func _relay_frame(data: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([(data.size() >> 24) & 255, (data.size() >> 16) & 255, (data.size() >> 8) & 255, data.size() & 255])
	out.append_array(data)
	return out


## The link dropped (or never came): tried again in `retry` ms, or at once (RELAY_BACK_MSEC) when a
## working link dropped, to lose little of the stream. What was waiting to be sent goes, as datagrams
## lost would: hellos come again each second, and the bridge's own sequencing heals the rest.
func _relay_lost(why: String, retry := RELAY_RETRY_MSEC) -> void:
	if _relay_greeted and not why.begins_with("refused"):
		retry = RELAY_BACK_MSEC
	if _relay != null:
		_relay.disconnect_from_host()
	_relay = null
	_relay_greeted = false
	_relay_in = PackedByteArray()
	_relay_out = PackedByteArray()
	_relay_retry_at = Time.get_ticks_msec() + retry
	_set_relay_state(why if why.begins_with("refused") else "lost: " + why)


## A command for the relay: queued for the I/O thread; written at once when the thread has stopped
## (the goodbye in disconnect_from), if the link is up. Commands may follow the greeting before the
## relay answers it: it reads them in order.
func _relay_put(data: PackedByteArray) -> void:
	if _relay == null:
		return  # not connected: lost, as a datagram would be (the relay is greeted first, so it may follow)
	_relay_out.append_array(_relay_frame(data))
	if _io_thread == null:
		_relay.poll()
		if _relay.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			_relay.put_data(_relay_out)
		_relay_out = PackedByteArray()


func _relay_close() -> void:
	_relay_open = false
	if _relay != null:
		_relay.disconnect_from_host()
	_relay = null
	_relay_greeted = false
	_relay_in = PackedByteArray()
	_relay_out = PackedByteArray()


## The parsing thread: waits for datagrams from the I/O thread and reads their messages.
func _parse_loop() -> void:
	var json := JSON.new()
	var not_finite := RegEx.create_from_string(NOT_FINITE)
	while true:
		_parse_sem.wait()
		_io_mutex.lock()
		var run := _io_run
		var raw := _inbox
		var when := _inbox_usec
		_inbox = []
		_inbox_usec = PackedInt64Array()
		_io_mutex.unlock()
		if not run:
			return
		if raw.is_empty():
			continue
		var tracing := _udp_trace != null
		for i in raw.size():
			var packet: PackedByteArray = raw[i]
			var newest := -1
			var answers: Array = []
			var read := _read_datagram(json, not_finite, packet)
			var msgs: Array = read[0]
			var types := {}
			for msg: Dictionary in msgs:
				var t: Variant = msg.get("t")
				MessageDecode.prepare(msg, t)  # its pure decoding here, off the main thread
				newest = maxi(newest, _int_or(msg.get("k"), -1))
				if t == "cmdr":
					answers.append(msg)
				if tracing:
					types[t] = int(types.get(t, 0)) + 1
			var entry := [packet.size(), msgs, read[1], read[2], newest, answers, read[3], when[i] if i < when.size() else 0, types, read[4]]
			_io_mutex.lock()
			_parsed.append(entry)
			_io_mutex.unlock()


func _stop_io() -> void:
	if _io_thread == null:
		return
	_io_mutex.lock()
	_io_run = false
	_io_mutex.unlock()
	_io_thread.wait_to_finish()
	_io_thread = null
	_keepalive = PackedByteArray()
	if _parse_thread != null:
		_parse_sem.post()
		_parse_thread.wait_to_finish()
		_parse_thread = null
	_inbox.clear()
	_inbox_usec.clear()
	_parsed.clear()


func _process(delta: float) -> void:
	ModGraphics.poll()
	if bind_error != OK or not _sock_bound():
		return
	if resync_guard:
		var hello_now := Time.get_ticks_msec()
		if hello_now - _hello_msec >= int(HELLO_INTERVAL * 1000.0):
			_hello_msec = hello_now
			_send_hello()
	else:
		_hello_timer += delta
		if _hello_timer >= HELLO_INTERVAL:
			_hello_timer = 0.0
			_send_hello()
	# Datagrams are read and parsed on the I/O and parsing threads (connect_to starts both whenever
	# the socket is open); the UI test's own socket has neither, and nothing to read.
	if _io_thread != null:
		_io_mutex.lock()
		var parsed := _parsed
		_parsed = []
		_io_mutex.unlock()
		if not parsed.is_empty():
			_last_read_msec = Time.get_ticks_msec()
		var t_route := Time.get_ticks_usec() if Probing.on else 0  # (--stutter-probe: br_route, the parsed datagrams queued)
		for entry: Array in parsed:
			stats["packets"] += 1
			stats["bytes"] += int(entry[0])
			var read_at := int(entry[7]) if int(entry[7]) > 0 else Time.get_ticks_usec()
			if belt_messages_first or priority_queue:
				_route(entry[1], entry[2], read_at)
			else:
				_waiting.append_array(entry[1])
				_waiting_len.append_array(entry[2])
				for _m in (entry[1] as Array).size():
					_waiting_usec.append(read_at)
					_waiting_checked.append(0)
			if int(entry[3]) > 0:
				stats["bad_json"] = int(stats.get("bad_json", 0)) + int(entry[3])
			if int(entry[9]) > 0:
				stats["bad_frames"] = int(stats.get("bad_frames", 0)) + int(entry[9])
			var k := int(entry[4])
			# A tick far behind the newest is a save loaded (or a new session): start from it.
			if k > newest_tick or (k >= 0 and k < newest_tick - 3600):
				newest_tick = k
			for answer: Dictionary in entry[5]:
				answer_read.emit(answer)
			_count_datagram(int(entry[6]), int(entry[0]), k, int(entry[7]), entry[8])
		if Probing.on:
			Probing.add("br_route", t_route)
	if not _holding and not _hold_kinds.is_empty():
		_release_held()  # before newer messages, which wait behind these meanwhile
	_drain()
	# A new session's mod starts at 0, and keeps the level through a resync: sent after each
	# handshake unless it is 0 and was never anything else.
	if not world_ready:
		_rate_sent = -1 if _rate_sent > 0 or update_rate > 0 else 0
	elif _rate_sent != update_rate:
		_rate_sent = update_rate
		send({"t": "rate", "l": update_rate})
	if not world_ready:
		_alt_sent = 0
	elif _alt_sent != alt_contents:
		_alt_sent = alt_contents
		var altc := {"t": "altc", "on": 1 if alt_contents > 0 else 0, "g": alt_contents}
		if loco_fuel_icons:
			altc["lf"] = 1
		send(altc)
	_check_handshake_stall(Time.get_ticks_msec())
	_check_nack_timeouts()
	if _pending_resync > 0 and connected:
		_send_resync()
	_check_timeout()


## Nothing handled for TIMEOUT_MSEC (and no pause on purpose): the connection is lost.
func _check_timeout() -> void:
	if connected and _quiet_by.is_empty() and Time.get_ticks_msec() - _last_packet_msec > TIMEOUT_MSEC:
		connected = false
		world_ready = false
		_welcome_read = false  # the hello asks for the welcome again (w 0)
		_nack_pending.clear()
		_nack_expired.clear()
		_reorder_clear()
		_live_waiting.clear()
		connection_lost.emit()


## The handshake's end lost: prototypes still incomplete and nothing reliable read for
## HANDSHAKE_STALL_MSEC. With resync_guard, `ready` read and waiting its turn in the queue (the
## sequence check as messages arrive saw it) is not lost: the drain will get to it.
func _check_handshake_stall(now: int) -> void:
	if not connected or world_ready or now - last_reliable_msec <= HANDSHAKE_STALL_MSEC:
		return
	if resync_guard and _seq_world_ready:
		return
	request_resync(true)


func _check_nack_timeouts() -> void:
	if not nack_enabled or not connected:
		return
	var now := Time.get_ticks_msec()
	if not _reorder.is_empty() and (now - _reorder_since > REORDER_MAX_MSEC or _reorder.size() > REORDER_MAX):
		_reorder_give_up(now)
	if not _nack_expired.is_empty():
		var stale: Array = []
		for key in _nack_expired:
			if now - int(_nack_expired[key]) > NACK_EXPIRED_GRACE_MSEC:
				stale.append(key)
		for key in stale:
			_nack_expired.erase(key)
	if _nack_pending.is_empty():
		return
	var expired: Array = []
	for key in _nack_pending:
		var sent_at := int(_nack_pending[key])
		if now - sent_at > NACK_TIMEOUT_MSEC:
			expired.append(key)
	if expired.is_empty():
		return
	for key in expired:
		_nack_pending.erase(key)
		_nack_expired[int(key)] = now
	stats["nack_timeouts"] += 1
	request_resync(not world_ready)
	if not _reorder.is_empty():
		_reorder_give_up(now)


## One datagram read: its number `n` (-1 without one) against the last, for `loss`, and its line in
## --udp-trace. A number below the last is the mod starting over (a save loaded): no loss.
func _count_datagram(n: int, bytes: int, k: int, usec: int, types: Dictionary) -> void:
	if n < 0:
		loss["unnumbered"] += 1
	else:
		loss["datagrams"] += 1
		if _dg_expected >= 0 and n > _dg_expected:
			loss["lost"] += n - _dg_expected
		_dg_expected = n + 1
	if _udp_trace != null:
		_udp_trace.store_line(JSON.stringify({"us": usec, "n": n, "b": bytes, "k": k, "m": types}))


## Messages waiting to be handled (read from their JSON), oldest first from _waiting_at, and the
## length of each one's text.
var _waiting: Array = []
var _waiting_len := PackedInt32Array()
## When each one's datagram was read (Time.get_ticks_usec), for --message-catchup.
var _waiting_usec := PackedInt64Array()
## Whether reliable sequence number `r` was already verified on arrival in _route().
var _waiting_checked := PackedByteArray()
var _waiting_at := 0
## Main-thread time a frame spends handling messages is its slice in frame_budget.gd (`messages`): a
## big base sends 6,000 belt items several times a second, which took 20-40 ms to handle in one frame
## and made the view stutter. The rest wait for the next frame; past BACKLOG_MESSAGES waiting, a
## frame takes up to twice as long (as the shared pool allows); fallen behind (--message-catchup), at
## least the whole 4 ms. 4 ms, not 6: the world's chunk rebuilds come after it in the
## same frame, and together they made the 20 ms frames walking on the owner's save.
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const Probing := preload("res://scripts/debug/probing.gd")
const ModGraphics := preload("res://scripts/world/mod_graphics.gd")
const MessageDecode := preload("res://scripts/net/message_decode.gd")
const WireDecode := preload("res://scripts/net/wire_decode.gd")
const BACKLOG_MESSAGES := 300
## This frame's message handling, in µs, for world.gd's share of the frame.
var frame_handle_usec := 0
## Messages that took longer than this to handle: [ms, type, bytes] (for --stutter-probe, kept
## only while it runs).
const SLOW_MESSAGE_USEC := 8000
var slow_messages: Array = []
## (--stutter-probe) Every message over SLOW_MESSAGE_USEC by type (slow_messages keeps only the first 200).
var slow_counts := {}


## For the UI test: a datagram's messages queued for _drain, as the parsing thread queues them.
func _queue(packet: PackedByteArray) -> void:
	stats["packets"] += 1
	stats["bytes"] += packet.size()
	var read := _read_datagram(_json, _not_finite, packet)
	_count_bad(read)
	var lengths: PackedInt32Array = read[1]
	for i in (read[0] as Array).size():
		_waiting.append(read[0][i])
		_waiting_len.append(lengths[i])
		_waiting_usec.append(Time.get_ticks_usec())
		_waiting_checked.append(0)


## A datagram's messages, with the JSON and RegEx of the thread it runs on: [messages (Dictionaries), their
## lengths, how many had numbers that aren't finite, the datagram's number (-1 without), 1 when a binary
## frame was bad]. Text is one JSON message or several joined by newlines (`b` in the hello); a datagram
## starting WireDecode.WIRE_MAGIC is binary frames (`bin`), JSON ones among them read as lines are. The
## `dg` line or frame is counted here, not handed on. Anything that isn't a JSON object is dropped.
func _read_datagram(json: JSON, not_finite: RegEx, packet: PackedByteArray) -> Array:
	var entries: Variant
	var sizes := PackedInt32Array()
	var dg := -1
	var bad_frames := 0
	if WireDecode.is_binary(packet):
		var got := WireDecode.read(packet)
		entries = got[0]
		sizes = got[1]
		dg = int(got[2])
		bad_frames = int(got[3])
	else:
		var text := MessageDecode.packet_text(packet)
		entries = text.split("\n", false) if text.contains("\n") else PackedStringArray([text])
	var msgs: Array = []
	var lengths := PackedInt32Array()
	var bad := 0
	var i := -1
	for entry: Variant in entries:
		i += 1
		if entry is Dictionary:
			# (A binary `ents` part's extras come as JSON text: parsed here as a line is.)
			if (entry as Dictionary).has("xi") and not WireDecode.ents_extras(entry, func(text: String) -> Variant: return _parse_with(json, not_finite, text)[0]):
				bad_frames += 1
				continue
			msgs.append(entry)
			lengths.append(sizes[i])
			continue
		var line: String = entry
		var got: Array = _parse_with(json, not_finite, line)
		if got[1]:
			bad += 1
		if got[0] is Dictionary:
			var msg: Dictionary = got[0]
			var t: Variant = msg.get("t")
			if t is String and t == "dg":
				# The datagram's number (the bridge's last line): counted, not handled.
				dg = _int_or(msg.get("n"), -1)
				continue
			msgs.append(msg)
			lengths.append(line.length())
	return [msgs, lengths, bad, dg, bad_frames]


func _count_bad(read: Array) -> void:
	if int(read[2]) > 0:
		stats["bad_json"] = int(stats.get("bad_json", 0)) + int(read[2])
	if int(read[4]) > 0:
		stats["bad_frames"] = int(stats.get("bad_frames", 0)) + int(read[4])


var _json := JSON.new()
## A bare inf, -inf or nan where a number goes: Factorio's table_to_json writes a Lua float that
## isn't finite as it is, which isn't JSON.
const NOT_FINITE := "([:,[]) *(-?)(inf|nan|-nan) *(?=[]},])"
var _not_finite := RegEx.create_from_string(NOT_FINITE)
var _bad_types := {}
var _bad_mutex := Mutex.new()


## One message's text as its Dictionary (or whatever else it held), null when it isn't JSON. A
## message with numbers that aren't finite (seen 4 times in a 30-minute session on a real busy
## base, the whole message lost) is read with them as 1e18, -1e18 or 0, counted in stats
## ("bad_json") and reported once per message type with where it was.
func parse(text: String) -> Variant:
	var got: Array = _parse_with(_json, _not_finite, text)
	if got[1]:
		stats["bad_json"] = int(stats.get("bad_json", 0)) + 1
	return got[0]


## [what `text` holds or null, whether it had numbers that aren't finite], with the JSON and RegEx
## of the thread it runs on.
func _parse_with(json: JSON, not_finite: RegEx, text: String) -> Array:
	if json.parse(text) == OK:
		return [json.data, false]
	if not (text.contains("inf") or text.contains("nan")):
		return [null, false]
	var fixed := not_finite.sub(text, "$1$2NOT_FINITE_$3", true)
	fixed = fixed.replace("-NOT_FINITE_inf", "-1e18").replace("NOT_FINITE_inf", "1e18")
	fixed = fixed.replace("-NOT_FINITE_nan", "0").replace("NOT_FINITE_-nan", "0").replace("NOT_FINITE_nan", "0")
	if json.parse(fixed) != OK:
		return [null, false]
	var data = json.data
	var kind := str(data.get("t", "?")) if data is Dictionary else "?"
	_bad_mutex.lock()
	var first := not _bad_types.has(kind)
	_bad_types[kind] = true
	_bad_mutex.unlock()
	if first:
		var at := maxi(text.find("inf"), text.find("nan"))
		push_warning("bridge: a '%s' message had a number that isn't finite (read as 1e18 or 0): ...%s..." % [kind, text.substr(maxi(0, at - 120), 160)])
	return [data, true]


## Checks reliable sequence numbering `r` at wire arrival time so priority messages can jump the
## bulk queue safely without false sequence gaps or dropping late arrival resyncs.
func _check_reliable_seq(msg: Dictionary, t: String) -> bool:
	if t == "dg":
		return true
	var seq_conn := _seq_connected or connected
	if msg.has("r"):
		var now := Time.get_ticks_msec()
		last_reliable_msec = now
		var r := _int_or(msg["r"], -1)
		if r < 1 or (seq_conn and r - _expected_r > 1000000):
			return false
		if t == "welcome":
			if resync_guard:
				_full_welcome_read = _full_wait
				# What waits before it is the old session's: dropped, not handled (_drain).
				_stale_until = _waiting.size()
			_expected_r = r + 1
			_seq_connected = true
			_seq_world_ready = false
			_nack_pending.clear()
			_nack_expired.clear()
			_live_waiting.clear()
			if resync_guard:
				_welcome_read = true
				_send_hello()  # says the welcome came (w 1) now, so the I/O thread's keepalive has it for a long frame
			return true
		if not seq_conn:
			return false
		if r < _expected_r:
			if nack_enabled and _nack_pending.has(r):
				_nack_pending.erase(r)
				stats["nack_hits"] += 1
				return true
			if nack_enabled and _nack_expired.has(r):
				var exp_at := int(_nack_expired[r])
				_nack_expired.erase(r)
				if now - exp_at <= NACK_EXPIRED_GRACE_MSEC:
					stats["nack_late_drops"] += 1
					return false
			request_resync(true)
			return false
		if r > _expected_r and _reorder_gap_ok.erase(r):
			pass  # past a gap _reorder gave up on: already counted, its resync asked for
		elif r > _expected_r:
			stats["gaps"] += 1
			var seq_ready := _seq_world_ready or (world_ready and _prio_barriers == 0)
			if nack_enabled and seq_ready and r - _expected_r <= NACK_MAX_GAP:
				var missing: Array = []
				for m: int in range(_expected_r, r):
					_nack_pending[m] = now
					missing.append(m)
				send({"t": "nack", "r": missing})
				stats["nacks_sent"] += 1
			else:
				request_resync(not seq_ready)
		_expected_r = r + 1
		if t == "ready":
			_seq_world_ready = true
		return true
	return seq_conn


## The chunk `(cx, cy)` an entity `add`/`upd`/`del` falls in, or null if coordinates are missing.
static func _delta_chunk(msg: Dictionary, t: String) -> Variant:
	if t == "del":
		if msg.has("x") and msg.has("y"):
			return Vector2i(floori(float(_int_or(msg["x"], 0)) / 256.0 / 32.0), floori(float(_int_or(msg["y"], 0)) / 256.0 / 32.0))
		return null
	var e: Variant = msg.get("e")
	if e is Array:
		var arr: Array = e
		if arr.size() >= 4:
			return Vector2i(floori(float(_int_or(arr[2], 0)) / 256.0 / 32.0), floori(float(_int_or(arr[3], 0)) / 256.0 / 32.0))
	return null


## (belt_messages_first + priority_queue) Routes incoming messages into P1 (`me`), P2 (player
## interactions & safe chunk deltas), P3 (`bs`), or bulk `_waiting`, keeping sequence order & barriers safe.
func _route(msgs: Array, lengths: PackedInt32Array, read_at: int) -> void:
	for i in msgs.size():
		var msg = msgs[i]
		var length := lengths[i] if i < lengths.size() else 0
		if priority_queue and msg is Dictionary:
			var dm: Dictionary = msg
			for e: Array in _reorder_in(dm, str(dm.get("t", "")), length, read_at):
				_route_one(e[0], int(e[1]), int(e[2]))
		else:
			_route_one(msg, length, read_at)


## One message routed (after _reorder_in): see _route.
func _route_one(msg: Variant, length: int, read_at: int) -> void:
	if msg is Dictionary:
		var d: Dictionary = msg
		var t := str(d.get("t", ""))
		if priority_queue and not _check_reliable_seq(d, t):
			return
		if PRIO_BARRIERS.has(t):
			_prio_barriers += 1
		if t == "chunk" or t == "ents":
			var cc := Vector2i(_int_or(d.get("cx"), 0), _int_or(d.get("cy"), 0))
			_chunk_waiting[cc] = int(_chunk_waiting.get(cc, 0)) + 1
		if priority_queue and _prio_barriers == 0 and connected and world_ready:
			if ME_MESSAGES.has(t):
				_me_waiting.append(d)
				return
			if PRIO_MESSAGES.has(t):
				_prio_waiting.append(d)
				return
			if CHUNK_DELTA_MESSAGES.has(t):
				var dc: Variant = _delta_chunk(d, t)
				# Not while the replay head holds anything: an unapplied ents slice there may hold the record this
				# delta changes (it falls through to _waiting, behind the head, counted by prio_delta_order).
				if dc is Vector2i and not _chunk_waiting.has(dc) and _replay_at >= _replay_head.size():
					_prio_waiting.append(d)
					return
			if coalesce_updates and LIVE_FAST_MESSAGES.has(t) and not d.has("r") and (t != "ie" or _chunk_waiting.is_empty()):
				_live_waiting.append(d)
				return
		if belt_messages_first:
			if BELT_MESSAGES.has(t) and not d.has("r"):
				if _belt_barriers == 0 and _belts_behind == 0:
					_belt_waiting.append(d)
					return
				_belts_behind += 1
			elif BELT_BARRIERS.has(t):
				_belt_barriers += 1
		if prio_delta_order and CHUNK_DELTA_MESSAGES.has(t):
			# Counted like chunk/ents: a later delta for the chunk waits behind this one.
			var wc: Variant = _delta_chunk(d, t)
			if wc is Vector2i:
				_chunk_waiting[wc] = int(_chunk_waiting.get(wc, 0)) + 1
	_waiting.append(msg)
	_waiting_len.append(length)
	_waiting_usec.append(read_at)
	_waiting_checked.append(1 if priority_queue else 0)


## The cue from the game (welcome `cue`, message `cue`): kept, and told when it changed.
func _set_cue(v: int) -> void:
	v = maxi(v, -1)
	if v == cue_tick:
		return
	cue_tick = v
	cue_changed.emit(v)


## (reliable_reorder) The gate in front of the sequence check, as messages arrive: a reliable message
## after a gap NACK can fill is held (and the gap NACKed); the message that fills it comes out with
## the held ones after it, in order. Returns [message, length, read usec] entries to hand on, oldest
## first. Gaps NACK can't fill (not ready, too wide) go on to the sequence check as before.
func _reorder_in(d: Dictionary, t: String, length: int, usec: int) -> Array:
	if not reliable_reorder or not nack_enabled or t == "dg" or not d.has("r"):
		return [[d, length, usec]]
	if t == "welcome":
		_reorder_clear()  # a new session: what was held was the old one's
		return [[d, length, usec]]
	var r := _int_or(d["r"], -1)
	if r < 1 or not (_seq_connected or connected) or r - _expected_r > 1000000 or r < _expected_r:
		return [[d, length, usec]]
	var now := Time.get_ticks_msec()
	if r == _expected_r:
		if _nack_pending.erase(r):
			stats["nack_hits"] += 1
		if _reorder.is_empty():
			return [[d, length, usec]]
		var out: Array = [[d, length, usec]]
		var nx := r + 1
		while _reorder.has(nx):
			out.append(_reorder[nx])
			_reorder.erase(nx)
			nx += 1
		if _reorder.is_empty():
			_reorder_high = 0
		stats["reordered"] = int(stats.get("reordered", 0)) + out.size() - 1
		return out
	# r > _expected_r: a gap before it.
	if _reorder.has(r):
		return []  # a duplicate of one held
	var seq_ready := _seq_world_ready or (world_ready and _prio_barriers == 0)
	if not seq_ready or r - _expected_r > NACK_MAX_GAP or _reorder.size() >= REORDER_MAX:
		if _reorder.is_empty():
			return [[d, length, usec]]  # the sequence check resyncs, as before
		# Give up on the held gap: hand on what was held, then this one; resync.
		stats["gaps"] += 1
		var last := maxi(_reorder_high, _expected_r - 1)
		var given: Array = _reorder_flush(now)
		if r > last + 1:
			_reorder_gap_ok[r] = true
		_expire_pending_below(r, now)
		request_resync(not seq_ready)
		given.append([d, length, usec])
		return given
	if _nack_pending.erase(r):
		stats["nack_hits"] += 1
	var top := maxi(_reorder_high, _expected_r - 1)
	if r > top + 1:
		var missing: Array = []
		for m: int in range(top + 1, r):
			if not _nack_pending.has(m) and not _reorder.has(m):
				_nack_pending[m] = now
				missing.append(m)
		if not missing.is_empty():
			stats["gaps"] += 1
			send({"t": "nack", "r": missing})
			stats["nacks_sent"] += 1
	if _reorder.is_empty():
		_reorder_since = now
	_reorder[r] = [d, length, usec]
	_reorder_high = maxi(_reorder_high, r)
	return []


## Everything held, oldest first, each marked to pass the sequence check's gap quietly; and the
## NACKs still out for numbers below them expired (a late retransmit is dropped, not applied late).
func _reorder_flush(now: int) -> Array:
	var keys := _reorder.keys()
	keys.sort()
	var out: Array = []
	var prev := _expected_r - 1
	for k: int in keys:
		if k > prev + 1:
			_reorder_gap_ok[k] = true  # only where a gap is (a stale mark would hide a later one)
		prev = k
		out.append(_reorder[k])
	if not keys.is_empty():
		_expire_pending_below(int(keys[keys.size() - 1]), now)
	_reorder.clear()
	_reorder_high = 0
	stats["reorder_flushes"] = int(stats.get("reorder_flushes", 0)) + 1
	return out


func _expire_pending_below(r: int, now: int) -> void:
	var gone: Array = []
	for key: int in _nack_pending:
		if key < r:
			gone.append(key)
	for key: int in gone:
		_nack_pending.erase(key)
		_nack_expired[key] = now


## The gap timed out (or the buffer is too old or full): hand on what was held, in order, and resync.
func _reorder_give_up(now: int) -> void:
	var given := _reorder_flush(now)
	request_resync(not world_ready)
	for e: Array in given:
		if priority_queue:
			_route_one(e[0], int(e[1]), int(e[2]))
		else:
			_handle(e[0])


func _reorder_clear() -> void:
	_reorder.clear()
	_reorder_high = 0
	_reorder_gap_ok.clear()


## Book-keeping for a message taken from _waiting.
func _routed_out(msg: Dictionary) -> void:
	var t := str(msg.get("t", ""))
	if PRIO_BARRIERS.has(t):
		_prio_barriers = maxi(0, _prio_barriers - 1)
	var cc: Variant = null
	if t == "chunk" or t == "ents":
		cc = Vector2i(_int_or(msg.get("cx"), 0), _int_or(msg.get("cy"), 0))
	elif prio_delta_order and CHUNK_DELTA_MESSAGES.has(t):
		cc = _delta_chunk(msg, t)
	if cc is Vector2i:
		var left := int(_chunk_waiting.get(cc, 0)) - 1
		if left > 0:
			_chunk_waiting[cc] = left
		else:
			_chunk_waiting.erase(cc)
	if BELT_BARRIERS.has(t):
		_belt_barriers = maxi(0, _belt_barriers - 1)
	elif _belts_behind > 0 and BELT_MESSAGES.has(t) and not msg.has("r"):
		_belts_behind -= 1


func _coalesce_skips(queue: Array, from_idx: int, stop_at_barrier: bool) -> Dictionary:
	if Probing.on:
		var t_co := Time.get_ticks_usec()
		var out := _coalesce_skips_do(queue, from_idx, stop_at_barrier)
		Probing.add("br_coalesce", t_co)  # (--stutter-probe: the passes over the waiting queue)
		return out
	return _coalesce_skips_do(queue, from_idx, stop_at_barrier)


func _coalesce_skips_do(queue: Array, from_idx: int, stop_at_barrier: bool) -> Dictionary:
	var skips := {}
	if not coalesce_updates or not world_ready or queue.size() - from_idx <= 1:
		return skips
	var single_last := {}  # String type -> int last index
	var multi_ticks := {}  # String type -> Dictionary(int k -> {"parts": int, "seen": Dictionary})
	for i in range(from_idx, queue.size()):
		var item: Variant = queue[i]
		if not (item is Dictionary):
			continue
		var msg: Dictionary = item
		var t := str(msg.get("t", ""))
		if stop_at_barrier and PRIO_BARRIERS.has(t):
			break
		if msg.has("r"):
			continue
		if SINGLE_SNAPSHOT_MESSAGES.has(t):
			single_last[t] = i
		elif MULTI_SNAPSHOT_MESSAGES.has(t):
			var k := _int_or(msg.get("k"), -1)
			if k < 0:
				continue
			var part := _int_or(msg.get("part"), 1)
			var parts := maxi(1, _int_or(msg.get("parts"), 1))
			if not multi_ticks.has(t):
				multi_ticks[t] = {}
			var by_tick: Dictionary = multi_ticks[t]
			if not by_tick.has(k):
				by_tick[k] = {"parts": parts, "seen": {}}
			var entry: Dictionary = by_tick[k]
			entry["parts"] = maxi(int(entry["parts"]), parts)
			var seen: Dictionary = entry["seen"]
			seen[part] = true
	var multi_best := {}  # String type -> int newest complete tick
	for t_key in multi_ticks:
		var t_str := str(t_key)
		var by_tick: Dictionary = multi_ticks[t_str]
		var best_k := -1
		for k_val in by_tick:
			var k_int := int(k_val)
			var entry: Dictionary = by_tick[k_int]
			var parts := int(entry["parts"])
			var seen: Dictionary = entry["seen"]
			if parts <= 1 or seen.size() >= parts:
				if k_int > best_k:
					best_k = k_int
		if best_k >= 0:
			multi_best[t_str] = best_k
	if single_last.is_empty() and multi_best.is_empty():
		return skips
	for i in range(from_idx, queue.size()):
		var item: Variant = queue[i]
		if not (item is Dictionary):
			continue
		var msg: Dictionary = item
		var t := str(msg.get("t", ""))
		if stop_at_barrier and PRIO_BARRIERS.has(t):
			break
		if msg.has("r"):
			continue
		if single_last.has(t):
			if i < int(single_last[t]):
				skips[i] = true
		elif multi_best.has(t):
			var k := _int_or(msg.get("k"), -1)
			if k >= 0 and k < int(multi_best[t]):
				skips[i] = true
	return skips


## (--stutter-probe, Probing.on) Each fast lane's handled messages are timed one by one: the slowest of the frame is
## Probing.note_message's, and the lanes' totals are Probing parts `br_me`, `br_prio`, `br_live`, `br_belt` (br_fast's
## shares). Off the probe nothing more is timed.
func _drain_fast(queue: Array, stat_key: String, probe_key := "") -> Array:
	if queue.is_empty():
		return queue
	var t0 := Time.get_ticks_usec()
	var skips := _coalesce_skips(queue, 0, false)
	var ran := 0
	var probe := Probing.on
	for i in queue.size():
		if skips.has(i):
			stats["coalesced"] += 1
			continue
		var msg: Dictionary = queue[i]
		var tm := Time.get_ticks_usec() if probe else 0
		_handle(msg, true, false)
		if probe:
			Probing.note_message(str(msg.get("t", "")), Time.get_ticks_usec() - tm)
		ran += 1
	var spent := Time.get_ticks_usec() - t0
	stats["handle_usec"] += spent
	stats[stat_key] = int(stats.get(stat_key, 0)) + ran
	if probe and probe_key != "":
		Probing.add(probe_key, t0)
	return []


func _drain_live() -> void:
	if _live_waiting.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var msgs := _live_waiting
	_live_waiting = []
	var skips := _coalesce_skips(msgs, 0, false)
	var ran := 0
	var probe := Probing.on
	for i in msgs.size():
		if skips.has(i):
			stats["coalesced"] += 1
			continue
		var msg: Dictionary = msgs[i]
		_last_packet_msec = Time.get_ticks_msec()
		if not connected:
			continue
		var tm := Time.get_ticks_usec() if probe else 0
		_handle(msg, true, false)
		if probe:
			Probing.note_message(str(msg.get("t", "")), Time.get_ticks_usec() - tm)
		ran += 1
	var spent := Time.get_ticks_usec() - t0
	stats["handle_usec"] += spent
	stats["live_first"] = int(stats.get("live_first", 0)) + ran
	if probe:
		Probing.add("br_live", t0)


## (belt_messages_first) The belts' messages read so far, handled before the others: as _handle does for a
## message without a sequence number, but the server tick (`k`) is left to the messages in order.
func _drain_belts() -> void:
	if _belt_waiting.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var msgs := _belt_waiting
	_belt_waiting = []
	var probe := Probing.on
	for msg: Dictionary in msgs:
		_last_packet_msec = Time.get_ticks_msec()
		if not connected:
			continue
		var t := str(msg.get("t", ""))
		if _hold_kinds.has(t):
			_held.append(msg)
			continue
		var tm := Time.get_ticks_usec() if probe else 0
		_emit(msg, t)
		if probe:
			Probing.note_message(t, Time.get_ticks_usec() - tm)
	var spent := Time.get_ticks_usec() - t0
	stats["handle_usec"] += spent
	stats["belt_first"] = int(stats.get("belt_first", 0)) + msgs.size()
	if probe:
		Probing.add("br_belt", t0)


func _drain() -> void:
	var t_fast := Time.get_ticks_usec() if Probing.on else 0  # (--stutter-probe: br_fast, the unbudgeted drains)
	if not _me_waiting.is_empty():
		_me_waiting = _drain_fast(_me_waiting, "me_first", "br_me")
	if not _prio_waiting.is_empty():
		_prio_waiting = _drain_fast(_prio_waiting, "prio_first", "br_prio")
	_drain_live()
	_drain_belts()
	if Probing.on:
		Probing.add("br_fast", t_fast)
	if _stale_until > _waiting_at:
		_drop_stale()
	var start := Time.get_ticks_usec()
	var remaining := (_replay_head.size() - _replay_at) + (_waiting.size() - _waiting_at)
	# (resync_guard) `ready` read but not handled: the handshake waits on the drain, so it gets the catch-up slice.
	var catch_up := behind(start) or (resync_guard and message_catchup and _seq_world_ready and not world_ready and remaining > 0)
	var limit := FrameBudget.grant(&"messages", 2 if remaining > BACKLOG_MESSAGES else 1, catch_up)
	_draining = true
	# (FrameBudget.fits: the next message's typical cost by its type counted before it starts, --budget-predict.)
	var handled := 0
	# One outer loop: a message in the waiting loop that puts entries in front (a live `ents` message's slices,
	# requeue_front) has them run this frame while time is left, not always a frame later (--drain-head-again=off:
	# they waited for the next frame as before).
	while true:
		while limit > 0 and _replay_at < _replay_head.size():
			var rp := _replay_head[_replay_at] as Replay
			var rk := rp.kind if replay_kinds else "replay"
			if not FrameBudget.fits(start, limit, handled, FrameBudget.item_est(&"messages", rk)):
				break
			var tr := Time.get_ticks_usec()
			# Advanced before it runs: an entry calling requeue_front while it runs puts the new entries after
			# itself (it isn't run again, and the first new one isn't skipped).
			_replay_at += 1
			rp.run()
			var r_spent := Time.get_ticks_usec() - tr
			FrameBudget.note_item(&"messages", r_spent, rk)
			Probing.note_message(rk, r_spent)
			handled += 1
			if Time.get_ticks_usec() - start > limit:
				break
		if _replay_at >= _replay_head.size():
			_replay_head.clear()
			_replay_at = 0
		var wait_skips := _coalesce_skips(_waiting, _waiting_at, true) if (limit > 0 and _replay_at >= _replay_head.size()) else {}
		while limit > 0 and _replay_at >= _replay_head.size() and _waiting_at < _waiting.size():
			if Time.get_ticks_usec() - start > limit:
				break
			var t0 := Time.get_ticks_usec()
			var idx := _waiting_at
			var msg = _waiting[idx]
			var mt := str((msg as Dictionary).get("t", "")) if msg is Dictionary else ((msg as Replay).kind if (msg is Replay and replay_kinds) else "replay")
			if handled > 0 and not wait_skips.has(idx) and not FrameBudget.fits(start, limit, handled, FrameBudget.item_est(&"messages", mt)):
				break
			var length := _waiting_len[idx] if idx < _waiting_len.size() else 0
			var seq_checked := idx < _waiting_checked.size() and _waiting_checked[idx] != 0
			_waiting_at += 1
			if msg is Dictionary:
				if _belt_barriers > 0 or _belts_behind > 0 or _prio_barriers > 0 or not _chunk_waiting.is_empty():
					_routed_out(msg)
				if wait_skips.has(idx):
					stats["coalesced"] += 1
					continue
				var wt := str((msg as Dictionary).get("t", ""))
				_handle(msg, seq_checked, true)
				if PRIO_BARRIERS.has(wt):
					wait_skips = _coalesce_skips(_waiting, _waiting_at, true)
				var spent := Time.get_ticks_usec() - t0
				Probing.note_message(wt, spent)
				FrameBudget.note_item(&"messages", spent, wt)
				handled += 1
				if Probing.on and spent > SLOW_MESSAGE_USEC:
					var st := str(msg.get("t", ""))
					slow_counts[st] = int(slow_counts.get(st, 0)) + 1
					if slow_messages.size() < 200:
						slow_messages.append([spent / 1000.0, st, length])
			elif msg is Replay:
				(msg as Replay).run()
				var rw_spent := Time.get_ticks_usec() - t0
				FrameBudget.note_item(&"messages", rw_spent, mt)
				Probing.note_message(mt, rw_spent)
				handled += 1
			if Time.get_ticks_usec() - start > limit:
				break
		if not drain_head_again or limit <= 0 or _replay_at >= _replay_head.size() or Time.get_ticks_usec() - start > limit:
			break
	_draining = false
	frame_handle_usec = Time.get_ticks_usec() - start
	if Probing.on:
		Probing.add("br_drain", start)  # (--stutter-probe: the budgeted loop, handlers included)
	stats["handle_usec"] += frame_handle_usec
	FrameBudget.spent(&"messages", frame_handle_usec, (_replay_head.size() - _replay_at) + (_waiting.size() - _waiting_at))
	if _waiting_at >= _waiting.size():
		_waiting.clear()
		_waiting_len.clear()
		_waiting_usec.clear()
		_waiting_checked.clear()
		_waiting_at = 0
		_stale_until = 0
	elif _waiting_at > 4096:
		_waiting = _waiting.slice(_waiting_at)
		_waiting_len = _waiting_len.slice(_waiting_at)
		_waiting_usec = _waiting_usec.slice(_waiting_at)
		_waiting_checked = _waiting_checked.slice(_waiting_at)
		_stale_until = maxi(0, _stale_until - _waiting_at)
		_waiting_at = 0


## (resync_guard) The messages read before the newest welcome: the old session's, which the new one
## replaces (the bridge starts its handshake over: world, prototypes, chunks sent again). Handling them
## only kept the drain behind; they leave the queue's books as handled ones do.
func _drop_stale() -> void:
	var until := mini(_stale_until, _waiting.size())
	var books := _belt_barriers > 0 or _belts_behind > 0 or _prio_barriers > 0 or not _chunk_waiting.is_empty()
	for idx in range(_waiting_at, until):
		var msg: Variant = _waiting[idx]
		if books and msg is Dictionary:
			_routed_out(msg as Dictionary)
		_waiting[idx] = null
	stale_dropped += maxi(0, until - _waiting_at)
	_waiting_at = maxi(_waiting_at, until)
	_stale_until = 0


## A message kept by the client and handled again (world.gd's kept chunks, `same`): handed straight
## to its handler, not through _handle (its sequence number and tick are old).
class Replay:
	var handler: Callable
	var msg: Dictionary
	## (--replay-kinds) "replay:<its message type>", the budget's estimate key for it.
	var kind := "replay"

	func run() -> void:
		if handler.is_valid():
			handler.call(msg)


var _draining := false


## Whether messages are being handled now (_drain): replays put in front are handled this frame or
## the next, within the message slice.
func draining() -> bool:
	return _draining


## Kept messages to handle next, before everything waiting: [[handler, msg], ...], in order. A kept
## chunk's dozen messages were handled inside its `same` message, 10-15 ms for a busy chunk
## (client-cpu.md 7); this way the message slice stops between them.
func requeue_front(entries: Array) -> void:
	var head: Array = []
	for e: Array in entries:
		var r := Replay.new()
		r.handler = e[0]
		r.msg = e[1]
		var t := str(r.msg.get("t", ""))
		if t != "":
			r.kind = "replay:" + t
		head.append(r)
	if _replay_at < _replay_head.size():
		head.append_array(_replay_head.slice(_replay_at))
	_replay_head = head
	_replay_at = 0


## Whether the messages have fallen behind (--message-catchup): the oldest waiting was read longer
## than catchup_usec before `now` (Time.get_ticks_usec).
func behind(now: int) -> bool:
	return message_catchup and _waiting_at < _waiting_usec.size() and now - _waiting_usec[_waiting_at] > catchup_usec


## How long the oldest message waiting has waited since its datagram was read, in ms (0: none waits).
func waiting_msec() -> int:
	if _waiting_at >= _waiting_usec.size():
		return 0
	return int((Time.get_ticks_usec() - _waiting_usec[_waiting_at]) / 1000)


## Messages received but not handled yet (for tests and the F4 line).
## Milliseconds since the last datagram came: a paused game's bridge sends nothing.
func silent_msec() -> int:
	return Time.get_ticks_msec() - maxi(_last_read_msec, _last_packet_msec)


func waiting_count() -> int:
	return (_replay_head.size() - _replay_at) + (_waiting.size() - _waiting_at)


## One datagram from the mod, handled at once: a message, or several joined by newlines (`b` in the hello: sending a
## datagram costs Factorio about a millisecond, so the mod fills each one). Anything that isn't a
## JSON object is dropped (tests/bridge_fuzz_test.gd throws garbage at this).
func receive(packet: PackedByteArray) -> void:
	stats["packets"] += 1
	stats["bytes"] += packet.size()
	var read := _read_datagram(_json, _not_finite, packet)
	_count_bad(read)
	for msg: Dictionary in read[0]:
		for e: Array in _reorder_in(msg, str(msg.get("t", "")), 0, 0):
			_handle(e[0])


## A JSON number as an int, or `default` for anything else. Packets come from a local port any
## program can write to, so their fields aren't trusted to be numbers.
static func _int_or(v: Variant, default: int) -> int:
	if v is int:
		return v
	if v is float and is_finite(v) and absf(v) < 9.0e18:
		return int(v)
	return default


func _exit_tree() -> void:
	_stop_io()
	send({"t": "bye"})


## Sets the bridge's work budget per tick, in work units (it clamps it to 50-20000).
func set_work_budget(units: int) -> void:
	send({"t": "budget", "u": units})


## Alt-mode on or off, for the chests' contents (J6): a new turning on gets a new number.
func set_alt_contents(on: bool) -> void:
	if on and alt_contents == 0:
		_alt_turns += 1
		alt_contents = _alt_turns
	elif not on:
		alt_contents = 0


func send_priority(cmd: Dictionary) -> void:
	send(cmd)


func send(cmd: Dictionary) -> void:
	if capture != null:
		capture.append(JSON.stringify(cmd))
		return
	if bind_error != OK or not _sock_bound():
		return
	var data := JSON.stringify(cmd).to_utf8_buffer()
	var is_prio := priority_queue and PRIORITY_COMMANDS.has(str(cmd.get("t", "")))
	if _io_thread != null:
		if is_prio and not via_relay and _nudp != null:
			_send_mutex.lock()
			var direct: bool = _nudp != null and bool(_nudp.is_bound())
			if direct:
				_nudp.put_packet(data)
			_send_mutex.unlock()
			if direct:
				stats["prio_sent"] = int(stats.get("prio_sent", 0)) + 1
				return
		_io_mutex.lock()
		if is_prio:
			_outbox_prio.append(data)
			stats["prio_sent"] = int(stats.get("prio_sent", 0)) + 1
		else:
			_outbox.append(data)
		if via_relay and cmd.get("t") == "hello":
			_relay_hello = data
		if cmd.get("t") == "hello":
			_keepalive = data if resync_guard and _int_or(cmd.get("w"), 0) == 1 else PackedByteArray()
			_keepalive_msec = Time.get_ticks_msec()
		_io_mutex.unlock()
	else:
		_sock_put(data)


## The game is paused on purpose for `reason` (on), or resumes (off): no timeout meanwhile, and the
## wait for the first packet after it starts again.
func expect_quiet(reason: String, on: bool) -> void:
	if on:
		_quiet_by[reason] = true
	elif _quiet_by.erase(reason):
		_last_packet_msec = Time.get_ticks_msec()


## The wait before the next full resync: FULL_RESYNC_COOLDOWN_MSEC, doubled for each one already asked
## since `ready` was last handled (resync_guard), up to FULL_RESYNC_MAX_MSEC.
func full_resync_cooldown() -> int:
	if not resync_guard or _full_streak <= 0:
		return FULL_RESYNC_COOLDOWN_MSEC
	return mini(FULL_RESYNC_COOLDOWN_MSEC << mini(_full_streak, 8), FULL_RESYNC_MAX_MSEC)


func request_resync(full: bool) -> void:
	_pending_resync = maxi(_pending_resync, 2 if full else 1)


func _send_resync() -> void:
	var full := _pending_resync == 2
	var now := Time.get_ticks_msec()
	if now - _last_resync_msec < (full_resync_cooldown() if full else CHUNK_RESYNC_COOLDOWN_MSEC):
		return
	if full and resync_guard and _full_wait and _full_welcome_read:
		return  # the last one's welcome waits in the queue: the drain gets to it first (kept pending)
	_last_resync_msec = now
	_pending_resync = 0
	if full:
		stats["full_resyncs"] += 1
		if resync_guard:
			_full_streak += 1
			_full_wait = true
			_full_welcome_read = false
		send({"t": "resync", "full": 1})
	elif resync_chunks.is_valid():
		var list: Array = resync_chunks.call()
		if not list.is_empty():
			stats["resyncs"] += 1
			send({"t": "resync", "full": 0, "c": list})


func _send_hello() -> void:
	# z: bi, ih and mv lists delta-coded (see PROTOCOL.md), most of a busy base's traffic.
	# dc: decoratives (dprotos, dec), as Settings → Graphics → Decoratives says (main.gd sets it).
	# bs: belts are simulated here (belt_sim.gd): the mod sends each lane once and then only what
	# changes (`bs`, not `bi`). A bridge older than `bs` sends `bi`, which nothing draws now, so
	# main's `bi` options (bl, bg, br) aren't asked for.
	# mg: mods' windows (mgui), as Settings → Interface says; 0 and the bridge doesn't read them.
	# dq: every datagram numbered (its last line, `dg`), so lost ones are counted (`loss`).
	# lv: told the counts of chunks kept after they leave the square (`kept`, world.gd's area cache).
	# ie: inserter hands as events (inserter_arms.gd, --inserter-events): 1 instead of the samples
	# (`ih`), 2 as well as them.
	var welcomed_now := connected or (resync_guard and _welcome_read)
	var hello := {"t": "hello", "v": PROTOCOL, "sid": _session, "w": 1 if welcomed_now else 0, "z": 1, "b": 1, "bs": 1,
		"mg": 1 if mod_windows else 0, "dq": 1, "lv": 1}
	if decoratives:
		hello["dc"] = 1
		# dd: how far they are drawn; a bridge before it sends every chunk's, as it always did.
		if decorative_distance > 0:
			hello["dd"] = decorative_distance
	if inserter_events > 0:
		hello["ie"] = inserter_events
	if inserter_handoff:
		hello["ho"] = 1
	# pn: the player this PC's Factorio joins as (Ctrl+F9's), who plays this client's character there.
	if factorio_player != "":
		hello["pn"] = factorio_player
	# bin: binary frames up to this wire version (wire_decode.gd); a bridge before them sends JSON as ever.
	if binary_messages:
		hello["bin"] = WireDecode.WIRE_VERSION
	if robot_sim:
		hello["rb"] = 1
	if distant_horizon_enabled:
		hello["lod"] = 1
	send(hello)


func _handle(msg: Dictionary, seq_checked := false, advance_tick := true) -> void:
	_last_packet_msec = Time.get_ticks_msec()
	var msg_k := _int_or(msg.get("k"), -1)
	if not seq_checked or advance_tick:
		server_tick = msg_k if msg_k >= 0 else server_tick
	newest_tick = maxi(newest_tick, msg_k if msg_k >= 0 else server_tick)  # (the UI test's messages come without the threads)
	var t := str(msg.get("t", ""))
	if t == "dg":
		return  # a datagram's number (the parsing thread counts them; this is the tests' path)
	if not seq_checked:
		if msg.has("r"):
			last_reliable_msec = _last_packet_msec
			var r := _int_or(msg["r"], -1)
			# A sequence number that isn't one, or one wildly ahead, is garbage, not a gap.
			if r < 1 or (connected and r - _expected_r > 1000000):
				return
			if t == "welcome":
				newest_tick = server_tick  # a save loaded a little earlier in its game counts from here
				mod_version = str(msg.get("mod", ""))
				save_id = str(msg.get("sid", ""))
				square_subs = _int_or(msg.get("sq"), 0)
				link_version = _int_or(msg.get("ext"), 0)
				_set_cue(_int_or(msg.get("cue"), -1))
				lod_supported = _int_or(msg.get("lod"), 0) == 1
				if _int_or(msg.get("v"), 0) != PROTOCOL:
					push_warning("Bridge mod %s speaks protocol %s, this client %d" % [mod_version, str(msg.get("v")), PROTOCOL])
				_expected_r = r + 1
				connected = true
				_seq_connected = true
				world_ready = false
				_seq_world_ready = false
				_pending_resync = 0
				_full_wait = false
				_full_welcome_read = false
				_nack_pending.clear()
				_nack_expired.clear()
				_live_waiting.clear()
				_clear_held()  # a new session: what waited was the old one's
				# The game's mods and its graphics list (mod_graphics.gd), before anything is drawn.
				ModGraphics.on_welcome(msg, send)
				welcomed.emit(msg)
				return
			if not connected:
				return
			if r < _expected_r:
				if nack_enabled and _nack_pending.has(r):
					_nack_pending.erase(r)
					stats["nack_hits"] += 1
				elif nack_enabled and _nack_expired.has(r):
					var exp_at := int(_nack_expired[r])
					_nack_expired.erase(r)
					if _last_packet_msec - exp_at <= NACK_EXPIRED_GRACE_MSEC:
						stats["nack_late_drops"] += 1
					else:
						request_resync(true)
					return
				else:
					# The numbering went backwards: the server reloaded a save. Start over.
					request_resync(true)
					return
			elif r > _expected_r and _reorder_gap_ok.erase(r):
				pass  # past a gap _reorder gave up on
			elif r > _expected_r:
				stats["gaps"] += 1
				if nack_enabled and world_ready and r - _expected_r <= NACK_MAX_GAP:
					var missing: Array = []
					for m: int in range(_expected_r, r):
						_nack_pending[m] = _last_packet_msec
						missing.append(m)
					send({"t": "nack", "r": missing})
					stats["nacks_sent"] += 1
				else:
					request_resync(not world_ready)
			if r >= _expected_r:
				_expected_r = r + 1
			if t == "ready":
				world_ready = true
				_seq_world_ready = true
				_full_streak = 0
		elif not connected:
			return
	else:
		if t == "welcome":
			if msg_k >= 0:
				server_tick = msg_k
			newest_tick = server_tick
			mod_version = str(msg.get("mod", ""))
			save_id = str(msg.get("sid", ""))
			square_subs = _int_or(msg.get("sq"), 0)
			link_version = _int_or(msg.get("ext"), 0)
			_set_cue(_int_or(msg.get("cue"), -1))
			lod_supported = _int_or(msg.get("lod"), 0) == 1
			if _int_or(msg.get("v"), 0) != PROTOCOL:
				push_warning("Bridge mod %s speaks protocol %s, this client %d" % [mod_version, str(msg.get("v")), PROTOCOL])
			connected = true
			_seq_connected = true
			world_ready = false
			_pending_resync = 0
			_full_wait = false
			_full_welcome_read = false
			_nack_pending.clear()
			_nack_expired.clear()
			_live_waiting.clear()
			_clear_held()
			ModGraphics.on_welcome(msg, send)
			welcomed.emit(msg)
			return
		if t == "ready":
			world_ready = true
			_full_streak = 0
	_last_packet_msec = Time.get_ticks_msec()
	if t == "gfx":
		ModGraphics.on_part(msg)
		return
	if t == "ext":
		ext_received.emit(msg)
		return
	if t == "cue":
		_set_cue(_int_or(msg.get("c"), -1))
		return
	if t == "wb":
		# The bridge's work per tick (once a second): kept here for whatever reads it.
		work_budget = msg
		work_budget_msec = Time.get_ticks_msec()
		return
	if _hold_kinds.has(t):
		_held.append(msg)
		if _holding and _held.size() - _held_at >= HELD_MAX:
			print("bridge: %d updates held for a screenshot: let go" % HELD_MAX)
			_holding = false
		return
	_emit(msg, t)


func _emit(msg: Dictionary, t: String) -> void:
	var t0 := Time.get_ticks_usec()
	message_received.emit(msg)
	handle_usec[t] = int(handle_usec.get(t, 0)) + Time.get_ticks_usec() - t0


# --- a screenshot's moment (moment_hold.gd) ------------------------------------------------------

## Message types that wait (`_held`) instead of being handled: set while the moment is held, and kept
## after it until what waited has been handled, so newer ones of those types stay behind it.
var _hold_kinds := {}
var _holding := false
var _held: Array = []
var _held_at := 0
## The most that wait (a few minutes of a busy base's updates); past it they are let go.
const HELD_MAX := 200000
## Main-thread time a frame gives to handling what waited (as the messages' own slice).
const RELEASE_USEC := 4000


## `types` (t -> true) wait from now on; {} lets them go, handled in the order they came over the
## next frames (_release_held).
func hold_types(types: Dictionary) -> void:
	if not types.is_empty():
		_hold_kinds = types
		_holding = true
	else:
		_holding = false


## How many messages wait (held or not handled yet after it).
func held_count() -> int:
	return _held.size() - _held_at


func _release_held() -> void:
	var start := Time.get_ticks_usec()
	while _held_at < _held.size():
		var msg: Dictionary = _held[_held_at]
		_held_at += 1
		_emit(msg, str(msg.get("t", "")))
		if Time.get_ticks_usec() - start > RELEASE_USEC:
			break
	if _held_at >= _held.size():
		_clear_held()


func _clear_held() -> void:
	_held.clear()
	_held_at = 0
	if not _holding:
		_hold_kinds = {}
