extends SceneTree
## WireDecodeNative (C++, client/native/belt_sim) against wire_decode.gd read_gd(), on the same datagrams: random
## valid frames of every kind (mv, bs, bfar, chunk, ents, st, ih, rb, JSON text, dg) and the same datagrams cut and
## byte-flipped. Results must be identical (types, values, Dictionary key order, lengths, dg, bad). Prints each
## path's time. Exits 1 at a difference; skips (exit 0) when the extension isn't loaded.
##   godot --headless --audio-driver Dummy --path client -s res://tests/wire_decode_native_test.gd -- [--n=N]

const WireDecode := preload("res://scripts/net/wire_decode.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")

var rng := RandomNumberGenerator.new()
var fails := 0


func _initialize() -> void:
	rng.seed = 20260422
	var n := 3000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--n="):
			n = int(a.substr(4))
	if not NativeLibrary.ensure() or not ClassDB.class_exists("WireDecodeNative"):
		print("wire_decode_native_test: WireDecodeNative not loaded, skipped")
		quit(0)
		return
	var nat: RefCounted = ClassDB.instantiate("WireDecodeNative")
	var packets: Array = []
	for i in n:
		packets.append(_datagram())
	var mutated: Array = []
	for p: PackedByteArray in packets:
		for k in 3:
			mutated.append(_mutate(p))
	var checked := 0
	for set_name: String in ["valid", "mutated"]:
		var group: Array = packets if set_name == "valid" else mutated
		var bad_count := 0
		for p: PackedByteArray in group:
			var a: Array = WireDecode.read_gd(p)
			var b: Array = nat.read(p, WireDecode.WIRE_VERSION)
			if int(a[3]) == 1:
				bad_count += 1
			var why := _diff(a, b, "read")
			checked += 1
			if why != "":
				fails += 1
				if fails <= 8:
					print("DIFF (%s) %s  packet=%s" % [set_name, why, p.hex_encode().substr(0, 200)])
		print("%s: %d datagrams, %d refused (bad)" % [set_name, group.size(), bad_count])
	# Timing on the valid set.
	var t0 := Time.get_ticks_usec()
	for p: PackedByteArray in packets:
		WireDecode.read_gd(p)
	var t_gd := Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for p: PackedByteArray in packets:
		nat.read(p, WireDecode.WIRE_VERSION)
	var t_nat := Time.get_ticks_usec() - t0
	var bytes := 0
	for p: PackedByteArray in packets:
		bytes += p.size()
	print("time over %d datagrams (%d KB): GDScript %.1f ms, native %.1f ms (%.1fx)" % [packets.size(), bytes / 1024, t_gd / 1000.0, t_nat / 1000.0, float(t_gd) / maxf(t_nat, 1.0)])
	# packet_text on odd bytes.
	for i in 300:
		var raw := PackedByteArray()
		for j in rng.randi_range(0, 40):
			raw.append(rng.randi() % 256 if rng.randf() < 0.3 else rng.randi_range(32, 126))
		var ma: String = preload("res://scripts/net/message_decode.gd").packet_text(raw)
		var mb: String = nat.packet_text(raw)
		if ma != mb:
			fails += 1
			if fails <= 8:
				print("DIFF packet_text %s: '%s' vs '%s'" % [raw.hex_encode(), ma, mb])
	print("wire_decode_native_test: %d checked, %d differences" % [checked, fails])
	quit(1 if fails > 0 else 0)


func _u32(out: PackedByteArray, v: int) -> void:
	out.append(v & 255)
	out.append((v >> 8) & 255)
	out.append((v >> 16) & 255)
	out.append((v >> 24) & 255)


func _block(out: PackedByteArray, count: int, signed_range := 100000) -> void:
	var wide := rng.randf() < 0.3
	out.append(8 if wide else 4)
	_u32(out, count)
	for i in count:
		var v := rng.randi_range(-signed_range, signed_range)
		if rng.randf() < 0.05:
			v = rng.randi_range(-2000000000, 2000000000)
		_u32(out, v)
		if wide:
			_u32(out, -1 if v < 0 else 0)


func _fixed(out: PackedByteArray, a: int, b: int) -> void:
	_u32(out, a)
	_u32(out, b)


func _frame(kind: int, flags: int, body: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([kind, flags])
	_u32(out, body.size())
	out.append_array(body)
	return out


func _head(rel: bool) -> PackedByteArray:
	var b := PackedByteArray()
	_u32(b, rng.randi())
	if rel:
		_u32(b, rng.randi())
	return b


func _one_frame(version: int) -> PackedByteArray:
	var kind: int = [0, 1, 16, 17, 18, 19, 20, 21, 22, 23][rng.randi() % 10]
	var rel := rng.randf() < 0.4
	var flags := 1 if rel else 0
	var b := PackedByteArray()
	match kind:
		0:
			var s := '{"t":"x","a":%d}' % rng.randi()
			if rng.randf() < 0.3:
				s += " h\u00e9llo \u4e2d"
			b.append_array(s.to_utf8_buffer())
			flags = 0
		1:
			for i in 3:
				_u32(b, rng.randi())
			flags = 0
		16:
			b = _head(rel)
			_fixed(b, rng.randi_range(0, 3), rng.randi_range(1, 4))
			_u32(b, rng.randi_range(0, 2))
			_block(b, 5 * rng.randi_range(0, 30))
		17:
			b = _head(rel)
			for i in 4:
				_u32(b, rng.randi_range(0, 100))
			_u32(b, rng.randi_range(-1000, 1000))
			_u32(b, rng.randi_range(-1000, 1000))
			_u32(b, rng.randi_range(0, 10))
			_u32(b, rng.randi_range(0, 1))
			# lm(14 a record), sl (variable), ew 5, sh 3, pc 6, pu 4, dl 2, of 2
			_bs_block(b, 14)
			_sl_block(b)
			_bs_block(b, 5)
			_bs_block(b, 3)
			_bs_block(b, 6)
			_bs_block(b, 4)
			_bs_block(b, 2)
			_bs_block(b, 2)
			var ids := rng.randi_range(0, 5)
			_block(b, ids)
			var names := PackedStringArray()
			for i in ids:
				names.append(["iron-plate", "copper-cable", "gr\u00fcn", "x"][rng.randi() % 4])
			var text := ",".join(names).to_utf8_buffer()
			_u32(b, text.size())
			b.append_array(text)
			if version >= 5 and rng.randf() < 0.5:
				_block(b, 7 * rng.randi_range(1, 5))
		18:
			b = PackedByteArray()
			_u32(b, rng.randi())
			_u32(b, rng.randi_range(-50, 50))
			_u32(b, rng.randi_range(-50, 50))
			var c := rng.randi_range(0, 12)
			_block(b, 5 * c)
			_block(b, 2 * c)
			if rng.randf() < 0.5:
				_block(b, 2 * c)
			else:
				_block(b, 0)
		19:
			b = _head(rel)
			for i in 6:
				_u32(b, rng.randi_range(0, 50))
			_block(b, 2 * rng.randi_range(0, 40), 1100)
		20:
			b = _head(rel)
			for i in 4:
				_u32(b, rng.randi_range(0, 9))
			var cnt := rng.randi_range(0, 20)
			_block(b, 5 * cnt)
			var nx := mini(cnt, rng.randi_range(0, 3))
			var blk := PackedByteArray()
			blk.append(4)
			_u32(blk, nx)
			for i in nx:
				_u32(blk, i)
			b.append_array(blk)
			if nx > 0:
				var arr: Array = []
				for i in nx:
					arr.append({"a": i})
				var t := JSON.stringify(arr).to_utf8_buffer()
				_u32(b, t.size())
				b.append_array(t)
			else:
				_u32(b, 0)
		21:
			b = _head(rel)
			_block(b, 2 * rng.randi_range(0, 6))
			_block(b, 2 * rng.randi_range(0, 3))
			_block(b, 2 * rng.randi_range(0, 3))
		22:
			b = _head(rel)
			_fixed(b, rng.randi_range(0, 3), rng.randi_range(1, 4))
			_u32(b, rng.randi_range(0, 2))
			_block(b, 4 * rng.randi_range(0, 10))
		23:
			b = _head(rel)
			for i in 5:
				_u32(b, rng.randi_range(0, 9))
			_block(b, 11 * rng.randi_range(0, 8))
			_block(b, rng.randi_range(0, 4))
	return _frame(kind, flags, b)


## A block of count records of `wide` numbers (the first two a unit and a line index).
func _bs_block(out: PackedByteArray, wide: int) -> void:
	var records := rng.randi_range(0, 6)
	var is64 := rng.randf() < 0.3
	out.append(8 if is64 else 4)
	_u32(out, records * wide)
	for r in records:
		for j in wide:
			var v := rng.randi_range(0, 5000)
			if j == 1 or (wide == 14 and j == 13):
				v = rng.randi_range(-3, 4)
			_u32(out, v)
			if is64:
				_u32(out, 0 if v >= 0 else -1)


func _sl_block(out: PackedByteArray) -> void:
	var records := rng.randi_range(0, 4)
	var nums: Array = []
	for r in records:
		var n := rng.randi_range(0, 3)
		nums.append_array([rng.randi_range(0, 999), rng.randi_range(-3, 4), rng.randi_range(0, 99), n])
		for k in n * 4:
			nums.append(rng.randi_range(0, 99999))
	out.append(4)
	_u32(out, nums.size())
	for v: int in nums:
		_u32(out, v)


func _datagram() -> PackedByteArray:
	var version := rng.randi_range(1, WireDecode.WIRE_VERSION)
	var out := PackedByteArray([WireDecode.WIRE_MAGIC, version])
	for i in rng.randi_range(1, 4):
		out.append_array(_one_frame(version))
	return out


func _mutate(p: PackedByteArray) -> PackedByteArray:
	var q := p.duplicate()
	var mode := rng.randi() % 4
	if mode == 0 and q.size() > 3:
		q.resize(rng.randi_range(0, q.size() - 1))
	elif mode == 1 and q.size() > 0:
		for i in rng.randi_range(1, 3):
			q[rng.randi() % q.size()] = rng.randi() % 256
	elif mode == 2 and q.size() > 8:
		q[rng.randi_range(2, 5)] = rng.randi() % 256
	elif q.size() > 0:
		q[rng.randi() % q.size()] ^= 1 << (rng.randi() % 8)
	return q


## "" when a and b are the same (types, values, Dictionary key order), else where they differ.
func _diff(a: Variant, b: Variant, path: String) -> String:
	if typeof(a) != typeof(b):
		return "%s: type %d vs %d" % [path, typeof(a), typeof(b)]
	if a is Dictionary:
		var ka: Array = (a as Dictionary).keys()
		var kb: Array = (b as Dictionary).keys()
		if ka != kb:
			return "%s: keys %s vs %s" % [path, ka, kb]
		for k: Variant in ka:
			var d := _diff(a[k], b[k], "%s.%s" % [path, k])
			if d != "":
				return d
		return ""
	if a is Array:
		if (a as Array).size() != (b as Array).size():
			return "%s: size %d vs %d" % [path, (a as Array).size(), (b as Array).size()]
		for i in (a as Array).size():
			var d := _diff(a[i], b[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	if a != b:
		return "%s: %s vs %s" % [path, str(a).substr(0, 60), str(b).substr(0, 60)]
	return ""
