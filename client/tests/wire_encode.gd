extends RefCounted
## Tests only: a `bs` or `bfar` message, as its JSON gives it, written as the bridge writes it for a client of
## wire version 2 by default, or the `version` given: from 5 a `bs` part's crossing hints (`sx`) follow qu's text
## as one more block when it has any (docs/PROTOCOL.md "Binary frames"; belt_sim.lua part_bin, belt_items.lua far_finish,
## tools/protocol.py encode_message), so a capture replays through wire_decode.gd as a binary stream would
## (tests/belt_bs_replay.gd --binary, ui_test's _binary_belts).

const WireDecode := preload("res://scripts/net/wire_decode.gd")


## [unit number, line index] of a lane key (minus a key: the line negative; 0: 0, 0).
static func lane_pair(key: int) -> Array:
	if key == 0:
		return [0, 0]
	var a := absi(key)
	var unit := (a - 1) / WireDecode.LANE_KEYS
	var line := a - unit * WireDecode.LANE_KEYS
	return [unit, line if key > 0 else -line]


## One bs list from JSON's layout to the block's (its keys as two numbers).
static func _split(field: String, flat: Array) -> Array:
	var out: Array = []
	if field == "sl":
		var i := 0
		while i + 2 < flat.size():
			var n := int(flat[i + 2])
			out.append_array(lane_pair(int(flat[i])))
			for j in range(i + 1, i + 3 + n * 4):
				out.append(int(flat[j]))
			i += 3 + n * 4
		return out
	if field == "of":
		for v: Variant in flat:
			out.append(int(v))
		return out
	var stride: int = WireDecode.BS_STRIDE[field]
	for i in range(0, flat.size() - stride + 1, stride):
		for j in stride:
			if j == 0 or (field == "lm" and j == 11):
				out.append_array(lane_pair(int(flat[i + j])))
			else:
				out.append(int(flat[i + j]))
	return out


static func _u32(out: PackedByteArray, v: int) -> void:
	var at := out.size()
	out.resize(at + 4)
	out.encode_u32(at, v)


static func _s32(out: PackedByteArray, v: int) -> void:
	var at := out.size()
	out.resize(at + 4)
	out.encode_s32(at, v)


## A block: width (8 when a number is past 32 bits), count, the numbers.
static func _block(out: PackedByteArray, numbers: Array) -> void:
	var wide := false
	for v: int in numbers:
		wide = wide or v < -2147483648 or v > 2147483647
	out.append(8 if wide else 4)
	_u32(out, numbers.size())
	var at := out.size()
	out.resize(at + numbers.size() * (8 if wide else 4))
	for v: int in numbers:
		if wide:
			out.encode_s64(at, v)
			at += 8
		else:
			out.encode_s32(at, v)
			at += 4


static func _ints(v: Variant) -> Array:
	var out: Array = []
	if v is Array:
		for x: Variant in v:
			out.append(int(x))
	return out


## The frame (kind, flags, length, body) of a `bs` or `bfar` message; empty for any other.
static func frame(msg: Dictionary, version := 2) -> PackedByteArray:
	var body := PackedByteArray()
	var kind := 0
	if msg.get("t") == "bs":
		kind = WireDecode.KIND_BS
		_u32(body, int(msg.get("k", 0)))
		for key: String in ["part", "parts", "p", "w"]:
			_u32(body, int(msg.get(key, 0)))
		_s32(body, int(msg.get("fx", 0)))
		_s32(body, int(msg.get("fy", 0)))
		_u32(body, int(msg.get("fr", 0)))
		_u32(body, int(msg.get("ld", 0)))
		for field: String in WireDecode.BS_FIELDS:
			_block(body, _split(field, msg.get(field, []) if msg.get(field) is Array else []))
		var qu: Array = msg.get("qu", []) if msg.get("qu") is Array else []
		var ids: Array = []
		var names := PackedStringArray()
		for i in range(0, qu.size() - 1, 2):
			ids.append(int(qu[i]))
			names.append(str(qu[i + 1]))
		_block(body, ids)
		var text := ",".join(names).to_utf8_buffer()
		_u32(body, text.size())
		body.append_array(text)
		var sx := _ints(msg.get("sx"))
		if version >= 5 and not sx.is_empty():
			_block(body, sx)
	elif msg.get("t") == "bfar":
		kind = WireDecode.KIND_BFAR
		_u32(body, int(msg.get("k", 0)))
		_s32(body, int(msg.get("cx", 0)))
		_s32(body, int(msg.get("cy", 0)))
		for key: String in ["l", "c", "h"]:
			_block(body, _ints(msg.get(key)))
	else:
		return PackedByteArray()
	var out := PackedByteArray([kind, 0])
	_u32(out, body.size())
	out.append_array(body)
	return out


## A datagram of version 2 (or `version`) holding these messages' frames.
static func datagram(msgs: Array, version := 2) -> PackedByteArray:
	var out := PackedByteArray([WireDecode.WIRE_MAGIC, version])
	for m: Dictionary in msgs:
		out.append_array(frame(m, version))
	return out


## The message written and read back (wire_decode.gd), as the client gets it from a binary stream; {} when
## that fails.
static func round_trip(msg: Dictionary, version := 2) -> Dictionary:
	var got: Array = WireDecode.read(datagram([msg], version))
	if int(got[3]) != 0 or (got[0] as Array).size() != 1:
		return {}
	return got[0][0]
