extends RefCounted
## Messages turned into what their handlers use, on the bridge's parsing thread (bridge.gd
## _parse_loop) instead of the main thread (client-cpu.md 15): pure work on the message alone.
##   chart   its pixels as an Image (`_img`, the palette indexes `px` dropped there): a chunk's
##           1,024 pixels were looked up one by one in GDScript on the main thread (ui_model.gd)
##   chunk   its tiles' runs as one id per tile (`_tiles`, a PackedInt32Array; chunk_view.gd)
## A message whose fields aren't what they should be (the fuzz tests send anything) is left as it
## came, and its handler reads it the old way. `--decode-thread=off`: everything on the main thread.

const Switches := preload("res://scripts/switches.gd")

const CHUNK := 32

static var enabled := Switches.on("--decode-thread")


## A datagram's text. The mod's JSON is ASCII but for names and text players typed (UTF-8), so ASCII
## is taken as it is. Anything can write to the client's port, and Godot's UTF-8 decoding prints an
## error for every byte that isn't valid (10-30 ms each on Windows): a 250-byte packet of noise took
## a second or more, and bridge_fuzz_test.gd ran past its time limit. Other packets are checked
## here first and their invalid bytes read as "?", as quietly as the rest.
static func packet_text(packet: PackedByteArray) -> String:
	var ascii := packet.get_string_from_ascii()
	# get_string_from_ascii stops at a NUL and maps each byte over 127 to one character of two
	# UTF-8 bytes: the same length and size means plain ASCII.
	if ascii.length() == packet.size() and ascii.to_utf8_buffer().size() == packet.size():
		return ascii
	return utf8_cleaned(packet).get_string_from_utf8()


## `packet` with each byte that doesn't belong to a valid UTF-8 sequence (RFC 3629: no overlong
## forms, surrogates or code points past U+10FFFF) replaced by "?"; `packet` itself when all are valid.
static func utf8_cleaned(packet: PackedByteArray) -> PackedByteArray:
	var out := packet
	var copied := false
	var n := packet.size()
	var i := 0
	while i < n:
		var b: int = packet[i]
		if b < 0x80:
			i += 1
			continue
		# The bytes that follow a lead byte, and the range its first follower must be in.
		var need := 0
		var lo := 0x80
		var hi := 0xBF
		if b >= 0xC2 and b <= 0xDF:
			need = 1
		elif b == 0xE0:
			need = 2
			lo = 0xA0
		elif b >= 0xE1 and b <= 0xEF:
			need = 2
			if b == 0xED:
				hi = 0x9F
		elif b == 0xF0:
			need = 3
			lo = 0x90
		elif b >= 0xF1 and b <= 0xF3:
			need = 3
		elif b == 0xF4:
			need = 3
			hi = 0x8F
		var ok := need > 0 and i + need < n
		if ok:
			for k in need:
				var c: int = packet[i + 1 + k]
				if c < (lo if k == 0 else 0x80) or c > (hi if k == 0 else 0xBF):
					ok = false
					break
		if ok:
			i += need + 1
			continue
		if not copied:
			out = packet.duplicate()
			copied = true
		out[i] = 0x3F
		i += 1
	return out


## On the parsing thread, for each message read.
static func prepare(msg: Dictionary, t: Variant) -> void:
	if not enabled or not (t is String):
		return
	if t == "chart":
		_chart(msg)
	elif t == "chunk":
		_chunk(msg)


static func _num(v: Variant) -> bool:
	return v is float or v is int


static func _chart(msg: Dictionary) -> void:
	var n_v: Variant = msg.get("n")
	var pal_v: Variant = msg.get("pal")
	var px_v: Variant = msg.get("px")
	if not (_num(n_v) and pal_v is Array and px_v is Array):
		return
	var n := int(n_v)
	var px: Array = px_v
	if n <= 0 or n > 1024 or px.size() != n * n:
		return
	for v in px:
		if not _num(v):
			return
	for c in pal_v:
		if c is Array and (c as Array).size() >= 3 and not (_num(c[0]) and _num(c[1]) and _num(c[2])):
			return
	msg["_img"] = chart_image(n, pal_v, px)
	msg.erase("px")  # (freed here, not on the main thread)


## A chart's pixels: palette indexes into [r, g, b] rows (0-255), unknown ones black.
static func chart_image(n: int, pal: Array, px: Array) -> Image:
	var colours := PackedByteArray()
	colours.resize(pal.size() * 3)
	var known := PackedByteArray()
	known.resize(pal.size())
	for k in pal.size():
		var c: Array = pal[k] if pal[k] is Array else []
		if c.size() >= 3:
			colours[k * 3] = int(c[0])
			colours[k * 3 + 1] = int(c[1])
			colours[k * 3 + 2] = int(c[2])
			known[k] = 1
	var data := PackedByteArray()
	data.resize(n * n * 3)
	for i in px.size():
		var k := int(px[i])
		if k >= 0 and k < known.size() and known[k] == 1:
			data[i * 3] = colours[k * 3]
			data[i * 3 + 1] = colours[k * 3 + 1]
			data[i * 3 + 2] = colours[k * 3 + 2]
	return Image.create_from_data(n, n, false, Image.FORMAT_RGB8, data)


static func _chunk(msg: Dictionary) -> void:
	var rle_v: Variant = msg.get("tiles")
	# (A binary frame's runs come packed, wire_decode.gd: whole numbers already.)
	if rle_v is PackedInt32Array or rle_v is PackedInt64Array:
		msg["_tiles"] = tiles_from_runs(rle_v)
		return
	if not (rle_v is Array):
		return
	var rle: Array = rle_v
	for v in rle:
		if not _num(v):
			return
	msg["_tiles"] = tiles_from_runs(rle)


## A chunk's tiles from their runs ([id, count, id, count...], an Array or a packed list), as chunk_view.gd
## set_tiles_rle reads them: CHUNK x CHUNK ids, those the runs don't reach 0.
static func tiles_from_runs(rle: Variant) -> PackedInt32Array:
	var ids := PackedInt32Array()
	ids.resize(CHUNK * CHUNK)
	var i := 0
	var n := 0
	while i + 1 < rle.size() and n < CHUNK * CHUNK:
		var id := int(rle[i])
		var count := mini(int(rle[i + 1]), CHUNK * CHUNK - n)
		for _k in count:
			ids[n] = id
			n += 1
		i += 2
	return ids
