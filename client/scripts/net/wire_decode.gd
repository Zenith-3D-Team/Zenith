extends RefCounted
## Binary frames from the bridge (docs/PROTOCOL.md, "Binary frames"; tools/protocol.py decode_frames is the
## same reader in Python). For a client whose hello says `bin`, a datagram is WIRE_MAGIC (a byte JSON text
## never starts with), the wire version, then frames: kind u8, flags u8, length u32, the body, little-endian.
##   kind 0    a JSON message as its text: everything not written in binary rides this way
##   kind 1    the datagram's number (`dg`): n, k, b as u32
##   kind 16   `mv`: k, part, parts, p as u32, then one block of movers, MV_STRIDE numbers a record
##   kind 17   `bs` (wire version 2): k, part, parts, p, w, fx, fy, fr, ld, then a block a list (BS_FIELDS), each
##             lane key as two numbers (unit number, line index), then qu: a block of ids and their names
##   kind 18   `bfar` (wire version 2): k u32, cx, cy i32, then blocks l, c, h (h empty: none)
##   kind 19   `chunk` (wire version 3, reliable): k, r, cx, cy (i32), parts, rs, rv, n, then the tiles' runs
##   kind 20   `ents` (wire version 3, reliable): k, r, cx, cy (i32), part, parts, then the records (ENT_STRIDE
##             numbers each), the indexes of those with extras, and their extras as one JSON array's text
##   kind 21   `st` (wire version 3, reliable): k, r, then blocks l, lc, ao (empty: absent)
##   kind 22   `ih` (wire version 3): k, part, parts, p, then one block of hands (IH_STRIDE numbers, whole)
##   kind 23   `rb` (wire version 4): k, part, parts, p, sm, snap, then blocks u (RB_STRIDE numbers each), g
## A block is width u8 (4 or 8), count u32, then `count` signed numbers, read with one call
## (PackedByteArray.to_int32_array: no GDScript loop over them). Every length is checked against the
## datagram: a bad frame drops the rest of it (counted in Bridge.stats "bad_frames").

const MessageDecode := preload("res://scripts/net/message_decode.gd")
const Switches := preload("res://scripts/switches.gd")

## --native-decode=off: the GDScript reader below (the default reads in C++, WireDecodeNative, when the
## extension is loaded; same results).
const NATIVE_CLASS := "WireDecodeNative"
static var native_enabled := Switches.on("--native-decode")
static var _native: RefCounted = null

const WIRE_MAGIC := 0xF3
## The highest wire version read (the hello's `bin`): 1 mv; 2 bs and bfar too; 3 chunk, ents, st and ih too;
## 4 rb too; 5 bs's crossing hints (`sx`: a block after qu's text, only in a part that has some). A datagram's
## second byte is the version the bridge answered.
const WIRE_VERSION := 5
const KIND_JSON := 0
const KIND_DG := 1
const KIND_MV := 16
const KIND_BS := 17
const KIND_BFAR := 18
const KIND_CHUNK := 19
const KIND_ENTS := 20
const KIND_ST := 21
const KIND_IH := 22
const KIND_RB := 23
const RB_STRIDE := 11
## An `ents` record in its block: unit, prototype id, x, y (1/256 tile), direction. Its extras, when it has
## any, are in the message's `xe` (Bridge parses the frame's JSON text, `xt`) at the same place as its index
## in `xi`.
const ENT_STRIDE := 5
## An `ih` hand: unit, hand x, hand y (1/256 tile), item id.
const IH_STRIDE := 4
## bs's lists in their blocks' order; a lane key (each record's first number, and lm's next) comes as the
## belt's unit number and the line index, signed as the key (lm's next -1: 0, -1).
const BS_FIELDS := ["lm", "sl", "ew", "sh", "pc", "pu", "dl", "of"]
## Numbers a record as JSON has them (sl: by its count), and whether it starts with a lane key.
const BS_STRIDE := {"lm": 12, "ew": 4, "sh": 2, "pc": 5, "pu": 3, "dl": 1, "of": 2}
## A `bs` crossing hint (wire version 5): unit, side, tick, out0, out1, in0, in1 (unique ids, 0: none).
const SX_STRIDE := 7
const LANE_KEYS := 8
const FLAG_RELIABLE := 1
## An `mv` record: unit, prototype id, x, y (1/256 tile), orientation x 1000 (NO_ORIENTATION: none).
const MV_STRIDE := 5
const NO_ORIENTATION := -1


static func is_binary(packet: PackedByteArray) -> bool:
	return packet.size() > 0 and packet[0] == WIRE_MAGIC


## A binary datagram read: [entries, lengths, dg, bad]. `entries` in order: a JSON frame's text (a String,
## parsed by the caller as a line is) or a binary message (a Dictionary, its list packed); `lengths` their
## bytes; `dg` the datagram's number (-1 without one); `bad` 1 when a frame was bad and the rest dropped.
static func read(packet: PackedByteArray) -> Array:
	var nat := native()
	if nat != null:
		return nat.read(packet, WIRE_VERSION)
	return read_gd(packet)


## The native reader, or null (switched off, or the extension isn't loaded).
static func native() -> RefCounted:
	if not native_enabled:
		return null
	if _native == null and ClassDB.class_exists(NATIVE_CLASS):
		_native = ClassDB.instantiate(NATIVE_CLASS)
	return _native


## read() in GDScript: the fallback, and the reference the native one is tested against.
static func read_gd(packet: PackedByteArray) -> Array:
	var entries: Array = []
	var lengths := PackedInt32Array()
	var dg := -1
	var size := packet.size()
	if size < 2 or packet[0] != WIRE_MAGIC or packet[1] < 1 or packet[1] > WIRE_VERSION:
		return [entries, lengths, dg, 1]
	var at := 2
	while at < size:
		if at + 6 > size:
			return [entries, lengths, dg, 1]
		var kind := packet[at]
		var flags := packet[at + 1]
		var start := at + 6
		var end := start + packet.decode_u32(at + 2)
		if end > size:
			return [entries, lengths, dg, 1]
		if kind == KIND_JSON:
			entries.append(MessageDecode.packet_text(packet.slice(start, end)))
			lengths.append(end - start)
		elif kind == KIND_DG:
			if end - start != 12:
				return [entries, lengths, dg, 1]
			dg = packet.decode_u32(start)
		else:
			var msg := message(kind, flags, packet, start, end, packet[1])
			if msg.is_empty():
				return [entries, lengths, dg, 1]
			entries.append(msg)
			lengths.append(end - start)
		at = end
	return [entries, lengths, dg, 0]


## One binary frame's message, or {} when its kind is unknown or its body doesn't add up. `version`: the
## datagram's wire version (its second byte).
static func message(kind: int, flags: int, packet: PackedByteArray, start: int, end: int, version := WIRE_VERSION) -> Dictionary:
	if kind >= KIND_CHUNK and kind <= KIND_IH:
		return _v3(kind, flags, packet, start, end)
	if kind == KIND_RB:
		return _rb(flags, packet, start, end)
	if kind == KIND_BS:
		return _bs(flags, packet, start, end, version)
	if kind == KIND_BFAR:
		return _bfar(packet, start, end)
	if kind != KIND_MV:
		return {}
	var p := start
	if p + 4 > end:
		return {}
	var msg := {"t": "mv", "k": packet.decode_u32(p)}
	p += 4
	if flags & FLAG_RELIABLE:
		if p + 4 > end:
			return {}
		msg["r"] = packet.decode_u32(p)
		p += 4
	if p + 12 > end:
		return {}
	msg["part"] = packet.decode_u32(p)
	msg["parts"] = packet.decode_u32(p + 4)
	var period := packet.decode_u32(p + 8)
	if period > 0:
		msg["p"] = period
	var block := _block(packet, p + 12, end)
	if block.is_empty() or int(block[1]) != end:
		return {}
	var numbers: Variant = block[0]
	var count: int = numbers.size()
	if count % MV_STRIDE != 0:
		return {}
	msg["l"] = numbers
	return msg


## [numbers (PackedInt32Array or PackedInt64Array), the block's end], or [] when it doesn't fit.
static func _block(packet: PackedByteArray, at: int, end: int) -> Array:
	if at + 5 > end:
		return []
	var width := packet[at]
	var count := packet.decode_u32(at + 1)
	if width != 4 and width != 8:
		return []
	var a := at + 5
	var b := a + width * count
	if b > end:
		return []
	if width == 4:
		return [packet.slice(a, b).to_int32_array(), b]
	return [packet.slice(a, b).to_int64_array(), b]


## A `bs` part (kind 17) as its JSON gives it, the lists as PackedInt64Array in JSON's layout (keys whole
## again), absent when empty as the bridge leaves them; {} when it doesn't add up. The keys are joined
## per record (slices, no loop over the items), here on the parsing thread.
static func _bs(flags: int, packet: PackedByteArray, start: int, end: int, version := WIRE_VERSION) -> Dictionary:
	var p := start
	if p + 4 > end:
		return {}
	var msg := {"t": "bs", "k": packet.decode_u32(p)}
	p += 4
	if flags & FLAG_RELIABLE:
		if p + 4 > end:
			return {}
		msg["r"] = packet.decode_u32(p)
		p += 4
	if p + 32 > end:
		return {}
	msg["part"] = packet.decode_u32(p)
	msg["parts"] = packet.decode_u32(p + 4)
	msg["p"] = packet.decode_u32(p + 8)
	msg["w"] = packet.decode_u32(p + 12)
	msg["fx"] = packet.decode_s32(p + 16)
	msg["fy"] = packet.decode_s32(p + 20)
	msg["fr"] = packet.decode_u32(p + 24)
	if packet.decode_u32(p + 28) != 0:
		msg["ld"] = packet.decode_u32(p + 28)
	p += 32
	for field: String in BS_FIELDS:
		var block := _block(packet, p, end)
		if block.is_empty():
			return {}
		p = block[1]
		if block[0].is_empty():
			continue
		var joined: Variant = _bs_join(field, _wide(block[0]))
		if joined == null:
			return {}
		msg[field] = joined
	var uids := _block(packet, p, end)
	if uids.is_empty() or int(uids[1]) + 4 > end:
		return {}
	p = uids[1]
	var n := packet.decode_u32(p)
	p += 4
	# (Wire version 5: after qu's text, a part with crossing hints has their block, sx; before 5 the text ends it.)
	var text_end := p + n
	if text_end > end or (text_end != end and version < 5):
		return {}
	if text_end != end:
		var sx := _block(packet, text_end, end)
		if sx.is_empty() or int(sx[1]) != end or (sx[0].size() % SX_STRIDE) != 0:
			return {}
		if sx[0].size() > 0:
			msg["sx"] = _wide(sx[0])
	var ids: Variant = uids[0]
	if n > 0 or ids.size() > 0:
		var names := packet.slice(p, text_end).get_string_from_utf8().split(",")
		if names.size() != ids.size():
			return {}
		var qu: Array = []
		for j in ids.size():
			qu.append(int(ids[j]))
			qu.append(names[j])
		msg["qu"] = qu
	return msg


static func _wide(numbers: Variant) -> PackedInt64Array:
	if numbers is PackedInt64Array:
		return numbers
	return PackedInt64Array(Array(numbers))


## A lane key from its unit number and line index (0, 0: 0; a negative line: minus the key).
static func lane_key(unit: int, line: int) -> int:
	if line == 0:
		return 0
	var key := unit * LANE_KEYS + absi(line)
	return key if line > 0 else -key


## One bs list from its block's layout (keys as two numbers) to JSON's; null when it doesn't add up.
static func _bs_join(field: String, flat: PackedInt64Array) -> Variant:
	var size := flat.size()
	if field == "of":
		return flat if size % 2 == 0 else null
	var out := PackedInt64Array()
	if field == "sl":
		var i := 0
		while i < size:
			if i + 4 > size:
				return null
			var n := flat[i + 3]
			if n < 0 or n > (size - i - 4) / 4:  # (not i + 4 + n * 4: a garbled n overflows it)
				return null
			out.append(lane_key(flat[i], flat[i + 1]))
			out.append_array(flat.slice(i + 2, i + 4 + n * 4))
			i += 4 + n * 4
		return out
	var stride: int = BS_STRIDE[field]
	var wide := stride + (2 if field == "lm" else 1)
	if size % wide != 0:
		return null
	for i in range(0, size, wide):
		out.append(lane_key(flat[i], flat[i + 1]))
		if field == "lm":
			out.append_array(flat.slice(i + 2, i + 12))
			out.append(lane_key(flat[i + 12], flat[i + 13]))
		elif stride > 1:
			out.append_array(flat.slice(i + 2, i + 1 + stride))
	return out


## A `bfar` chunk (kind 18): l, c and h (only when not empty) packed; {} when it doesn't add up.
static func _bfar(packet: PackedByteArray, start: int, end: int) -> Dictionary:
	if start + 12 > end:
		return {}
	var msg := {"t": "bfar", "k": packet.decode_u32(start), "cx": packet.decode_s32(start + 4), "cy": packet.decode_s32(start + 8)}
	var p := start + 12
	var lists: Array = []
	for j in 3:
		var block := _block(packet, p, end)
		if block.is_empty():
			return {}
		lists.append(block[0])
		p = block[1]
	var l: Variant = lists[0]
	var c: Variant = lists[1]
	var h: Variant = lists[2]
	if p != end or l.size() % 5 != 0 or c.size() * 5 != l.size() * 2 or (not h.is_empty() and h.size() != c.size()):
		return {}
	msg["l"] = l
	msg["c"] = c
	if not h.is_empty():
		msg["h"] = h
	return msg


## A wire version 3 message (kinds 19-22) as its JSON gives it, its lists packed; {} when it doesn't add up.
## `ents` keeps its extras' JSON text in `xt` for the caller to parse (Bridge, with its handling of numbers
## that aren't finite), which puts them in `xe`.
static func _v3(kind: int, flags: int, packet: PackedByteArray, start: int, end: int) -> Dictionary:
	var p := start
	if p + 4 > end:
		return {}
	var msg := {"k": packet.decode_u32(p)}
	p += 4
	if flags & FLAG_RELIABLE:
		if p + 4 > end:
			return {}
		msg["r"] = packet.decode_u32(p)
		p += 4
	if kind == KIND_CHUNK:
		if p + 24 > end:
			return {}
		msg["t"] = "chunk"
		msg["cx"] = packet.decode_s32(p)
		msg["cy"] = packet.decode_s32(p + 4)
		msg["parts"] = packet.decode_u32(p + 8)
		msg["rs"] = packet.decode_u32(p + 12)
		msg["rv"] = packet.decode_u32(p + 16)
		msg["n"] = packet.decode_u32(p + 20)
		var tiles := _block(packet, p + 24, end)
		if tiles.is_empty() or int(tiles[1]) != end or tiles[0].size() % 2 != 0:
			return {}
		msg["tiles"] = tiles[0]
		return msg
	if kind == KIND_ENTS:
		if p + 16 > end:
			return {}
		msg["t"] = "ents"
		msg["cx"] = packet.decode_s32(p)
		msg["cy"] = packet.decode_s32(p + 4)
		msg["part"] = packet.decode_u32(p + 8)
		msg["parts"] = packet.decode_u32(p + 12)
		var recs := _block(packet, p + 16, end)
		if recs.is_empty():
			return {}
		var xi := _block(packet, recs[1], end)
		if xi.is_empty() or int(xi[1]) + 4 > end:
			return {}
		p = xi[1]
		var n := packet.decode_u32(p)
		p += 4
		if p + n != end or recs[0].size() % ENT_STRIDE != 0:
			return {}
		var count: int = recs[0].size() / ENT_STRIDE
		for j: int in xi[0]:
			if j < 0 or j >= count:
				return {}
		if (n == 0) != xi[0].is_empty():
			return {}
		msg["e"] = recs[0]
		msg["xi"] = xi[0]
		if n > 0:
			msg["xt"] = MessageDecode.packet_text(packet.slice(p, end))
		return msg
	if kind == KIND_ST:
		msg["t"] = "st"
		for key: String in ["l", "lc", "ao"]:
			var block := _block(packet, p, end)
			if block.is_empty() or block[0].size() % 2 != 0:
				return {}
			p = block[1]
			if key == "l" or not block[0].is_empty():
				msg[key] = block[0]
		return msg if p == end else {}
	if p + 12 > end:
		return {}
	msg["t"] = "ih"
	msg["part"] = packet.decode_u32(p)
	msg["parts"] = packet.decode_u32(p + 4)
	var period := packet.decode_u32(p + 8)
	if period > 0:
		msg["p"] = period
	var hands := _block(packet, p + 12, end)
	if hands.is_empty() or int(hands[1]) != end or hands[0].size() % IH_STRIDE != 0:
		return {}
	msg["l"] = hands[0]
	return msg


## A simulated worker robots message (kind 23, wire version 4): k, optional r, part, parts, p, sm,
## snap, then packed u and optional g blocks; {} when it doesn't add up.
static func _rb(flags: int, packet: PackedByteArray, start: int, end: int) -> Dictionary:
	var p := start
	if p + 4 > end:
		return {}
	var msg := {"t": "rb", "k": packet.decode_u32(p)}
	p += 4
	if flags & FLAG_RELIABLE:
		if p + 4 > end:
			return {}
		msg["r"] = packet.decode_u32(p)
		p += 4
	if p + 20 > end:
		return {}
	msg["part"] = packet.decode_u32(p)
	msg["parts"] = packet.decode_u32(p + 4)
	msg["p"] = packet.decode_u32(p + 8)
	msg["sm"] = packet.decode_u32(p + 12)
	var snap := packet.decode_u32(p + 16)
	if snap != 0:
		msg["snap"] = snap
	var u_block := _block(packet, p + 20, end)
	if u_block.is_empty():
		return {}
	var g_block := _block(packet, int(u_block[1]), end)
	if g_block.is_empty() or int(g_block[1]) != end:
		return {}
	var u_nums: Variant = u_block[0]
	if u_nums.size() % RB_STRIDE != 0:
		return {}
	msg["u"] = u_nums
	var g_nums: Variant = g_block[0]
	if not g_nums.is_empty():
		msg["g"] = g_nums
	return msg


## A binary `ents` message's extras parsed (`xt`, a JSON array's text, one for each index in `xi`) into `xe`, by
## `parse` (text -> the parsed value or null). False when they don't match: the message is then bad.
static func ents_extras(msg: Dictionary, parse: Callable) -> bool:
	var xi: Variant = msg.get("xi", PackedInt32Array())
	var text: Variant = msg.get("xt")
	msg.erase("xt")
	if not (text is String):
		msg["xe"] = []
		return xi.is_empty()
	var got: Variant = parse.call(text)
	if not (got is Array) or (got as Array).size() != xi.size():
		return false
	msg["xe"] = got
	return true


## A binary `ents` message's records as JSON gives them ([unit, proto, x, y, direction, extras?]).
static func ents_records(msg: Dictionary) -> Array:
	var list: Variant = msg.get("e")
	if not packed(list):
		return list if list is Array else []
	var extras: Dictionary = {}
	var xi: Variant = msg.get("xi", PackedInt32Array())
	var xe: Variant = msg.get("xe", [])
	if xe is Array and xi.size() == (xe as Array).size():
		for j in xi.size():
			extras[int(xi[j])] = xe[j]
	var out: Array = []
	var n: int = list.size() / ENT_STRIDE
	for i in n:
		var a := i * ENT_STRIDE
		var rec := [int(list[a]), int(list[a + 1]), int(list[a + 2]), int(list[a + 3]), int(list[a + 4])]
		if extras.has(i):
			rec.append(extras[i])
		out.append(rec)
	return out


## Records in an `ents` message, packed or not (the chunk cache's byte estimate, counts).
static func ents_count(msg: Dictionary) -> int:
	var list: Variant = msg.get("e")
	if packed(list):
		return list.size() / ENT_STRIDE
	return (list as Array).size() if list is Array else 0


## A message with its packed lists as Arrays, as its JSON text gives them (the capture, the recorders,
## the overlay: readers that keep or cut the lists rather than walk them).
static func plain(msg: Dictionary) -> Dictionary:
	var out := msg
	if msg.get("t") is String and msg["t"] == "ents" and packed(msg.get("e")):
		out = msg.duplicate()
		out["e"] = ents_records(msg)
		out.erase("xi")
		out.erase("xe")
		out.erase("xt")
	for key: Variant in out:
		if packed(out[key]):
			if out == msg:
				out = msg.duplicate()
			out[key] = Array(out[key])
	return out


## Whether a message's list `l` came packed (a binary frame) rather than as JSON's arrays.
static func packed(list: Variant) -> bool:
	return list is PackedInt32Array or list is PackedInt64Array


## An `mv` message's records as JSON gives them ([unit, proto, x, y] or with the orientation), for readers
## that don't walk the packed list themselves (the debug overlay, the backdrop recorder): `l` itself when
## it is JSON's (a `z` one still delta-coded), the packed records whole otherwise.
static func mv_records(msg: Dictionary) -> Variant:
	var list: Variant = msg.get("l")
	if not packed(list):
		return list
	var out: Array = []
	var n: int = list.size()
	for i in range(0, n - MV_STRIDE + 1, MV_STRIDE):
		var rec := [int(list[i]), int(list[i + 1]), int(list[i + 2]), int(list[i + 3])]
		if int(list[i + 4]) != NO_ORIENTATION:
			rec.append(int(list[i + 4]))
		out.append(rec)
	return out

