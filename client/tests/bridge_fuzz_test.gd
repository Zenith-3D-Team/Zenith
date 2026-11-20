extends Node
## Throws malformed packets at the client's side of the protocol (scripts/net/bridge.gd's
## receive and _handle): random bytes, truncated JSON, deep nesting, fields of the wrong type,
## sequence numbers that are strings, negative, huge or out of order, duplicates; binary frames
## (wire_decode.gd) truncated, garbled and with lengths past the end, after its fixture (made by
## tools/protocol.py: tools/mod_tests/test_binary.py) is read as its JSON twin. Afterwards a new
## welcome must still connect and messages must still arrive. Exits 1 if a check fails; CI also
## fails on any SCRIPT ERROR in the output (a GDScript runtime error only stops that one call).
##
##   godot --headless --path client res://tests/bridge_fuzz_test.tscn

const BridgeScript := preload("res://scripts/net/bridge.gd")
const MessageDecode := preload("res://scripts/net/message_decode.gd")
const WireDecode := preload("res://scripts/net/wire_decode.gd")
const FIXTURE := "res://tests/fixtures/wire_frames.json"
const TYPES := ["welcome", "ready", "chunk", "ents", "add", "upd", "del", "sky", "me", "mv", "msg", "gui", "bs", "planet", "seg"]
const ROUNDS := 5000

var fails := 0
var rng := RandomNumberGenerator.new()


func check(cond: bool, what: String) -> void:
	if not cond:
		fails += 1
		print("FAIL: ", what)


func _ready() -> void:
	rng.seed = 1
	var b: Node = BridgeScript.new()
	add_child(b)
	var seen := [0]
	var count := func(_m: Dictionary) -> void:
		seen[0] += 1
	b.message_received.connect(count)

	# Packets aren't all ASCII: names players typed are UTF-8, and noise isn't UTF-8 at all.
	var name := "Station ü 東 🚂"
	var named := _bytes({"t": "msg", "text": name})
	check(MessageDecode.packet_text(named) == named.get_string_from_utf8() and MessageDecode.utf8_cleaned(named) == named,
		"a packet with UTF-8 names reads as before, untouched")
	var broken := PackedByteArray([0x7B, 0xC3, 0x22, 0xE2, 0x82, 0xFF, 0x7D, 0xF0, 0x9F, 0x9A])
	check(MessageDecode.packet_text(broken) == "{?\"???}???",
		"invalid UTF-8 (a cut sequence, a lone byte, a truncated end) reads as ?: %s" % MessageDecode.packet_text(broken))

	# Binary frames: protocol.py's datagram reads as the messages its JSON gives.
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	var frames: PackedByteArray = str(fixture["hex"]).hex_decode()
	var read: Array = b._read_datagram(JSON.new(), RegEx.create_from_string(BridgeScript.NOT_FINITE), frames)
	var got: Array = []
	for m: Dictionary in read[0]:
		var plain := m.duplicate()
		if m.get("t") == "mv":
			check(WireDecode.packed(m["l"]), "binary frames: mv's list arrives packed")
			plain["l"] = WireDecode.mv_records(m)
		elif m.get("t") == "bs" or m.get("t") == "bfar":
			check(m.has("dl") and WireDecode.packed(m["dl"]) or m.has("l") and (m["l"] is PackedInt32Array),
				"binary frames: %s's lists arrive packed" % m["t"])
			plain = WireDecode.plain(m)
		elif m.get("t") in ["chunk", "ents", "st", "ih"]:
			# (Wire version 3: the lists packed, ents' extras parsed from their JSON text into xe.)
			var key: String = {"chunk": "tiles", "ents": "e", "st": "l", "ih": "l"}[m["t"]]
			check(WireDecode.packed(m[key]), "binary frames: %s's list arrives packed" % m["t"])
			check(m["t"] != "ents" or (m.has("xe") and not m.has("xt")), "binary frames: ents' extras parsed (xe)")
			plain = WireDecode.plain(m)
		got.append(plain)
	check(_same(got, fixture["messages"]) and int(read[3]) == int(fixture["dg"]) and int(read[4]) == 0,
		"binary frames: the fixture reads as its JSON twin: %s" % [got])

	b.receive(_bytes({"t": "welcome", "r": 1, "v": 1, "k": 5}))
	check(b.connected, "a welcome connects")
	var noise_usec := 0
	var noise := 0
	for i in ROUNDS:
		match rng.randi() % 7:
			5:
				# A binary datagram cut short, or with bytes changed (a length past the end, a kind
				# that doesn't exist, a block of the wrong width).
				b.receive(frames.slice(0, rng.randi_range(0, frames.size())))
			6:
				var garbled := frames.duplicate()
				for k in rng.randi_range(1, 8):
					garbled[rng.randi_range(2, garbled.size() - 1)] = rng.randi() % 256
				b.receive(garbled)
			0:
				# Godot printed an error for each invalid byte, 10-30 ms each on Windows: a second or
				# more a packet, and this test ran past its time limit (MessageDecode.packet_text).
				var start := Time.get_ticks_usec()
				b.receive(_random_bytes())
				noise_usec += Time.get_ticks_usec() - start
				noise += 1
			1:
				var good := JSON.stringify(_junk_msg()).to_utf8_buffer()
				b.receive(good.slice(0, rng.randi_range(0, good.size())))
			2:
				b.receive(("[" if rng.randi() % 2 else "{\"a\":").repeat(rng.randi_range(1, 2000)).to_utf8_buffer())
			_:
				var m := _junk_msg()
				for k in rng.randi_range(1, 3):  # duplicated
					b.receive(_bytes(m))
	check(b.server_tick is int, "server_tick stays an int")
	check(int(b.stats.get("bad_frames", 0)) > 0, "bad binary frames are counted: %d" % int(b.stats.get("bad_frames", 0)))
	var noise_ms := noise_usec / 1000.0 / maxi(1, noise)
	check(noise_ms < 20.0, "a packet of random bytes is read quietly: %.2f ms on average (over a second before)" % noise_ms)

	b.receive(_bytes({"t": "welcome", "r": 1, "v": 1}))
	b.receive(_bytes({"t": "ready", "r": 2}))
	check(b.connected and b.world_ready, "a new welcome and ready still work after the fuzzing")
	var before: int = seen[0]
	b.receive(_bytes({"t": "sky", "d": 1, "n": 0, "k": 9}))
	b.receive(_bytes({"t": "add", "r": 3, "e": [1, 2, 0, 0, 0]}))
	check(seen[0] == before + 2 and b.server_tick == 9, "messages still arrive in order")
	before = seen[0]
	b.receive(frames)
	check(seen[0] == before + (fixture["messages"] as Array).size(), "a whole binary datagram's messages all arrive after the fuzzing")
	print("bridge fuzz: %d rounds (random bytes %.2f ms a packet), FAILS: %d" % [ROUNDS, noise_ms, fails])
	get_tree().quit(1 if fails else 0)


## The same values, numbers compared by value (JSON's are floats, a binary frame's ints).
func _same(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return float(a) == float(b)
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not _same(a[i], b[i]):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for k: Variant in a:
			if not b.has(k) or not _same(a[k], b[k]):
				return false
		return true
	return a == b


func _bytes(m: Dictionary) -> PackedByteArray:
	return JSON.stringify(m).to_utf8_buffer()


func _random_bytes() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(rng.randi_range(0, 300))
	for i in out.size():
		out[i] = rng.randi() % 256
	return out


func _junk(depth := 0) -> Variant:
	match rng.randi() % (12 if depth < 3 else 9):
		0: return null
		1: return true
		2: return rng.randi_range(-1000, 1000)
		3: return 1.0e300
		4: return -1.0e300
		5: return 0.5
		6: return "x".repeat(rng.randi_range(0, 3000))
		7: return TYPES[rng.randi() % TYPES.size()]
		8: return 2147483647 * 4
		9: return [_junk(depth + 1), _junk(depth + 1)]
		10: return {"t": _junk(depth + 1), "r": _junk(depth + 1)}
		_: return [[_junk(depth + 1)]]


func _junk_msg() -> Dictionary:
	var m := {}
	m["t"] = TYPES[rng.randi() % TYPES.size()] if rng.randi() % 4 else _junk()
	for key in ["r", "k", "v", "part", "parts", "l", "e", "x", "y"]:
		if rng.randi() % 2:
			m[key] = _junk()
	if rng.randi() % 3 == 0:
		m["r"] = rng.randi_range(-5, 50)
	return m
