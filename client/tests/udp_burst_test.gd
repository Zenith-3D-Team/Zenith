extends SceneTree
## How many of a burst's datagrams Godot's PacketPeerUDP (or the native socket, when the extension
## has one) hands over, read as bridge.gd's I/O thread reads: drain, then OS.delay_usec(1000). The
## sender is tools/.. or a scratch burst_send.py: datagrams starting with {"t":"dg","n":N}\n and a
## last {"t":"end","n":total}.
##
##   godot --headless --path client -s res://tests/udp_burst_test.gd -- --port=36699 [--socket=godot|native]
##       [--timeout=30] [--delay=1000]
##
## Prints the datagrams got and lost, the first gaps, and how long OS.delay_usec(delay) really takes.

const NativeLibrary := preload("res://scripts/native_library.gd")

var port := 36699
var socket_kind := "godot"
var timeout := 30.0
var delay_usec := 1000


func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			port = int(arg.get_slice("=", 1))
		elif arg.begins_with("--socket="):
			socket_kind = arg.get_slice("=", 1)
		elif arg.begins_with("--timeout="):
			timeout = float(arg.get_slice("=", 1))
		elif arg.begins_with("--delay="):
			delay_usec = int(arg.get_slice("=", 1))
	# How long the I/O thread's sleep really is on this OS.
	var t0 := Time.get_ticks_usec()
	for i in range(200):
		OS.delay_usec(delay_usec)
	print("OS.delay_usec(%d) x200 took %.2f ms each" % [delay_usec, (Time.get_ticks_usec() - t0) / 200000.0])
	var udp: Variant = null
	if socket_kind == "native":
		if not NativeLibrary.ensure() or not ClassDB.class_exists("UdpSocketNative"):
			print("UdpSocketNative isn't in the extension: skipped")
			quit(0)
			return
		udp = ClassDB.instantiate("UdpSocketNative")
		var err: int = udp.bind(port, "127.0.0.1", 8 * 1024 * 1024)
		if err != OK:
			print("bind failed: %d" % err)
			quit(1)
			return
		print("native socket: SO_RCVBUF %d" % int(udp.receive_buffer_size()))
	else:
		udp = PacketPeerUDP.new()
		var err: int = udp.bind(port, "127.0.0.1", 4 * 1024 * 1024)
		if err != OK:
			print("bind failed: %d" % err)
			quit(1)
			return
		print("PacketPeerUDP bound (Godot ring buffer 4 MB; the OS socket's SO_RCVBUF is whatever the OS gives)")
	print("listening on %d (%s)" % [port, socket_kind])
	var got := 0
	var lost := 0
	var expected := 1
	var total := -1
	var gaps: Array = []
	var last_read := Time.get_ticks_msec()
	var done := false
	var biggest_drain := 0
	while not done:
		var drained := 0
		while true:
			var packet: PackedByteArray
			if socket_kind == "native":
				packet = udp.get_packet()
				if packet.is_empty():
					break
			else:
				if udp.get_available_packet_count() <= 0:
					break
				packet = udp.get_packet()
			drained += 1
			last_read = Time.get_ticks_msec()
			var text := packet.get_string_from_utf8()
			var head := text.get_slice("\n", 0)
			var m: Variant = JSON.parse_string(head)
			if m is Dictionary:
				if m.get("t") == "end":
					total = int(m.get("n", -1))
					done = true
					break
				var n := int(m.get("n", 0))
				got += 1
				if n > expected:
					lost += n - expected
					if gaps.size() < 8:
						gaps.append([expected, n - 1])
				expected = n + 1
		biggest_drain = maxi(biggest_drain, drained)
		if Time.get_ticks_msec() - last_read > timeout * 1000:
			break
		OS.delay_usec(delay_usec)
	print("got %d, lost %d (%.2f%%), sent %d; biggest drain %d; first gaps %s" % [got, lost, 100.0 * lost / maxf(1.0, got + lost), total, biggest_drain, str(gaps)])
	quit(0)
