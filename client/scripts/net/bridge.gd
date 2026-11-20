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
## The tick of the message handled last: what the world mirror has reached.
var server_tick := 0
## The newest tick read off the socket: where the game is now. server_tick runs behind it while
## messages wait their turn (_drain) and catches up in bursts, so the game's UPS is measured on this
## (a busy base at 6 fps read 161 UPS at game speed 1 on server_tick).
var newest_tick := 0
var stats := {"packets": 0, "bytes": 0, "gaps": 0, "handle_usec": 0, "resyncs": 0, "full_resyncs": 0, "bad_json": 0, "bad_frames": 0}
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
var loco_fuel_icons := OS.get_cmdline_user_args().has("--loco-fuel-icons=on")
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
var _io_run := false
var _inbox: Array[PackedByteArray] = []
## When each of _inbox's datagrams was read (Time.get_ticks_usec), for --udp-trace.
var _inbox_usec := PackedInt64Array()
var _outbox: Array[PackedByteArray] = []
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
	for arg in OS.get_cmdline_user_args():
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
		elif arg.begins_with("--message-catchup-msec="):
			catchup_usec = maxi(0, int(arg.get_slice("=", 1))) * 1000
		elif arg.begins_with("--belt-messages-first="):
			belt_messages_first = arg.get_slice("=", 1) != "off"
		elif arg.begins_with("--binary-messages="):
			binary_messages = arg.get_slice("=", 1) != "off"
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
	if via_relay:
		_relay_put(data)
	elif _nudp != null:
		_nudp.put_packet(data)
	else:
		_udp.put_packet(data)


func _sock_close() -> void:
	if via_relay:
		_relay_close()
	elif _nudp != null:
		_nudp.close()
		_nudp = null
	elif _udp.is_bound():
		_udp.close()


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
	bind_error = OK
	server_tick = 0
	newest_tick = 0
	stats = {"packets": 0, "bytes": 0, "gaps": 0, "handle_usec": 0, "resyncs": 0, "full_resyncs": 0, "bad_json": 0, "bad_frames": 0}
	loss = {"datagrams": 0, "lost": 0, "unnumbered": 0}
	_dg_expected = -1
	_waiting.clear()
	_waiting_len.clear()
	_waiting_usec.clear()
	_waiting_at = 0
	_belt_waiting.clear()
	_belt_barriers = 0
	_belts_behind = 0
	_expected_r = 1
	_pending_resync = 0
	_last_packet_msec = 0
	_last_read_msec = 0
	last_reliable_msec = 0
	_quiet_by.clear()


## The I/O thread: sends what's queued, then reads everything waiting, about once a millisecond.
func _io_loop() -> void:
	while true:
		_io_mutex.lock()
		var run := _io_run
		var out := _outbox
		_outbox = []
		_io_mutex.unlock()
		for data in out:
			_sock_put(data)
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
		var out: Array = []
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
			out.append([packet.size(), msgs, read[1], read[2], newest, answers, read[3], when[i] if i < when.size() else 0, types, read[4]])
		_io_mutex.lock()
		_parsed.append_array(out)
		_io_mutex.unlock()


func _stop_io() -> void:
	if _io_thread == null:
		return
	_io_mutex.lock()
	_io_run = false
	_io_mutex.unlock()
	_io_thread.wait_to_finish()
	_io_thread = null
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
		for entry: Array in parsed:
			stats["packets"] += 1
			stats["bytes"] += int(entry[0])
			var read_at := int(entry[7]) if int(entry[7]) > 0 else Time.get_ticks_usec()
			if belt_messages_first:
				_route(entry[1], entry[2], read_at)
			else:
				_waiting.append_array(entry[1])
				_waiting_len.append_array(entry[2])
				for _m in (entry[1] as Array).size():
					_waiting_usec.append(read_at)
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
	if connected and not world_ready and Time.get_ticks_msec() - last_reliable_msec > HANDSHAKE_STALL_MSEC:
		request_resync(true)
	if _pending_resync > 0 and connected:
		_send_resync()
	if connected and _quiet_by.is_empty() and Time.get_ticks_msec() - _last_packet_msec > TIMEOUT_MSEC:
		connected = false
		world_ready = false
		connection_lost.emit()


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


## (belt_messages_first) A datagram's messages: the belts' to _belt_waiting while nothing that starts the belts
## over waits before them, the rest (and those) to _waiting in order.
func _route(msgs: Array, lengths: PackedInt32Array, read_at: int) -> void:
	for i in msgs.size():
		var msg = msgs[i]
		if msg is Dictionary:
			var t := str(msg.get("t", ""))
			if BELT_MESSAGES.has(t) and not msg.has("r"):
				if _belt_barriers == 0 and _belts_behind == 0:
					_belt_waiting.append(msg)
					continue
				_belts_behind += 1
			elif BELT_BARRIERS.has(t):
				_belt_barriers += 1
		_waiting.append(msg)
		_waiting_len.append(lengths[i] if i < lengths.size() else 0)
		_waiting_usec.append(read_at)


## (belt_messages_first) Book-keeping for a message taken from _waiting.
func _routed_out(msg: Dictionary) -> void:
	var t := str(msg.get("t", ""))
	if BELT_BARRIERS.has(t):
		_belt_barriers = maxi(0, _belt_barriers - 1)
	elif _belts_behind > 0 and BELT_MESSAGES.has(t) and not msg.has("r"):
		_belts_behind -= 1


## (belt_messages_first) The belts' messages read so far, handled before the others: as _handle does for a
## message without a sequence number, but the server tick (`k`) is left to the messages in order.
func _drain_belts() -> void:
	if _belt_waiting.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var msgs := _belt_waiting
	_belt_waiting = []
	for msg: Dictionary in msgs:
		_last_packet_msec = Time.get_ticks_msec()
		if not connected:
			continue
		var t := str(msg.get("t", ""))
		if _hold_kinds.has(t):
			_held.append(msg)
			continue
		_emit(msg, t)
	var spent := Time.get_ticks_usec() - t0
	stats["handle_usec"] += spent
	stats["belt_first"] = int(stats.get("belt_first", 0)) + msgs.size()


func _drain() -> void:
	_drain_belts()
	var start := Time.get_ticks_usec()
	var limit := FrameBudget.grant(&"messages", 2 if _waiting.size() - _waiting_at > BACKLOG_MESSAGES else 1, behind(start))
	_draining = true
	while limit > 0 and _waiting_at < _waiting.size():
		var t0 := Time.get_ticks_usec()
		var msg = _waiting[_waiting_at]
		var length := _waiting_len[_waiting_at]
		_waiting_at += 1
		if msg is Dictionary:
			if _belt_barriers > 0 or _belts_behind > 0:
				_routed_out(msg)
			_handle(msg)
			var spent := Time.get_ticks_usec() - t0
			if Probing.on and spent > SLOW_MESSAGE_USEC:
				var st := str(msg.get("t", ""))
				slow_counts[st] = int(slow_counts.get(st, 0)) + 1
				if slow_messages.size() < 200:
					slow_messages.append([spent / 1000.0, st, length])
		elif msg is Replay:
			(msg as Replay).run()
		if Time.get_ticks_usec() - start > limit:
			break
	_draining = false
	frame_handle_usec = Time.get_ticks_usec() - start
	stats["handle_usec"] += frame_handle_usec
	FrameBudget.spent(&"messages", frame_handle_usec, _waiting.size() - _waiting_at)
	if _waiting_at >= _waiting.size():
		_waiting.clear()
		_waiting_len.clear()
		_waiting_usec.clear()
		_waiting_at = 0
	elif _waiting_at > 4096:
		_waiting = _waiting.slice(_waiting_at)
		_waiting_len = _waiting_len.slice(_waiting_at)
		_waiting_usec = _waiting_usec.slice(_waiting_at)
		_waiting_at = 0


## A message kept by the client and handled again (world.gd's kept chunks, `same`): handed straight
## to its handler, not through _handle (its sequence number and tick are old).
class Replay:
	var handler: Callable
	var msg: Dictionary

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
		head.append(r)
	var lengths := PackedInt32Array()
	lengths.resize(head.size())
	# (Read now, for --message-catchup: a replay doesn't make the messages behind it count as late.)
	var read := PackedInt64Array()
	read.resize(head.size())
	read.fill(Time.get_ticks_usec())
	head.append_array(_waiting.slice(_waiting_at))
	lengths.append_array(_waiting_len.slice(_waiting_at))
	read.append_array(_waiting_usec.slice(_waiting_at))
	_waiting = head
	_waiting_len = lengths
	_waiting_usec = read
	_waiting_at = 0


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
	return _waiting.size() - _waiting_at


## One datagram from the mod, handled at once: a message, or several joined by newlines (`b` in the hello: sending a
## datagram costs Factorio about a millisecond, so the mod fills each one). Anything that isn't a
## JSON object is dropped (tests/bridge_fuzz_test.gd throws garbage at this).
func receive(packet: PackedByteArray) -> void:
	stats["packets"] += 1
	stats["bytes"] += packet.size()
	var read := _read_datagram(_json, _not_finite, packet)
	_count_bad(read)
	for msg: Dictionary in read[0]:
		_handle(msg)


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


func send(cmd: Dictionary) -> void:
	if capture != null:
		capture.append(JSON.stringify(cmd))
		return
	if bind_error != OK or not _sock_bound():
		return
	var data := JSON.stringify(cmd).to_utf8_buffer()
	if _io_thread != null:
		_io_mutex.lock()
		_outbox.append(data)
		if via_relay and cmd.get("t") == "hello":
			_relay_hello = data
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


func request_resync(full: bool) -> void:
	_pending_resync = maxi(_pending_resync, 2 if full else 1)


func _send_resync() -> void:
	var full := _pending_resync == 2
	var now := Time.get_ticks_msec()
	if now - _last_resync_msec < (FULL_RESYNC_COOLDOWN_MSEC if full else CHUNK_RESYNC_COOLDOWN_MSEC):
		return
	_last_resync_msec = now
	_pending_resync = 0
	if full:
		stats["full_resyncs"] += 1
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
	var hello := {"t": "hello", "v": PROTOCOL, "sid": _session, "w": 1 if connected else 0, "z": 1, "b": 1, "bs": 1,
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
	send(hello)


func _handle(msg: Dictionary) -> void:
	_last_packet_msec = Time.get_ticks_msec()
	server_tick = _int_or(msg.get("k"), server_tick)
	newest_tick = maxi(newest_tick, server_tick)  # (the UI test's messages come without the threads)
	var t := str(msg.get("t", ""))
	if t == "dg":
		return  # a datagram's number (the parsing thread counts them; this is the tests' path)
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
			if _int_or(msg.get("v"), 0) != PROTOCOL:
				push_warning("Bridge mod %s speaks protocol %s, this client %d" % [mod_version, str(msg.get("v")), PROTOCOL])
			_expected_r = r + 1
			connected = true
			world_ready = false
			_pending_resync = 0
			_clear_held()  # a new session: what waited was the old one's
			# The game's mods and its graphics list (mod_graphics.gd), before anything is drawn.
			ModGraphics.on_welcome(msg, send)
			welcomed.emit(msg)
			return
		if not connected:
			return
		if r < _expected_r:
			# The numbering went backwards: the server reloaded a save. Start over.
			request_resync(true)
			return
		if r > _expected_r:
			stats["gaps"] += 1
			request_resync(not world_ready)
		_expected_r = r + 1
		if t == "ready":
			world_ready = true
	elif not connected:
		return
	if t == "gfx":
		ModGraphics.on_part(msg)
		return
	if t == "ext":
		ext_received.emit(msg)
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
