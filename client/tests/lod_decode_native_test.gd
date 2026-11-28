extends SceneTree
## WireDecodeNative.lod_cells (C++, client/native/belt_sim) against lod_data.gd LodChunk.from_msg_gd (the
## GDScript decoder, `--native-lod-decode=off`), on the same Distant Horizon `lod` bodies: random valid ones at
## every resolution (tl/el as JSON's float Arrays, int Arrays, PackedInt32Array and PackedInt64Array) and the
## same bodies mutated (non-numbers, NaN/inf, negative or fractional ids, flags past 255, counts past or short of
## the cells, odd sizes, other types). Three paths must agree with the GDScript, cell for cell and refusal for
## refusal: from_msg calling the C++ itself, and from_msg reading `_lod` from MessageDecode.prepare (the parse
## thread's path). Prints the main thread's time per message before (GDScript) and after (`_lod` read).
## Exits 1 at a difference; skips (exit 0) when the extension isn't loaded.
##   godot --headless --audio-driver Dummy --path client -s res://tests/lod_decode_native_test.gd -- [--n=N]

const LodData := preload("res://scripts/world/lod_data.gd")
const MessageDecode := preload("res://scripts/net/message_decode.gd")
const NativeLibrary := preload("res://scripts/native_library.gd")

const RESOLUTIONS := [2, 4, 8, 16, 32]

var rng := RandomNumberGenerator.new()
var fails := 0


func _initialize() -> void:
	rng.seed = 20261126
	var n := 1000
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--n="):
			n = int(a.substr(4))
	if not NativeLibrary.ensure() or not ClassDB.class_exists("WireDecodeNative"):
		print("lod_decode_native_test: WireDecodeNative not loaded, skipped")
		quit(0)
		return
	if not ClassDB.class_has_method("WireDecodeNative", "lod_cells"):
		print("FAIL: WireDecodeNative has no lod_cells (old DLL?)")
		quit(1)
		return
	var checked := 0
	var refused := 0
	for res: int in RESOLUTIONS:
		var bodies: Array = []
		for i in n:
			bodies.append(_body(res, i % 4))
		var group: Array = bodies.duplicate()
		for b: Dictionary in bodies:
			for k in 4:
				group.append(_mutate(b))
		for msg: Dictionary in group:
			var why := _compare(msg)
			checked += 1
			if LodData.LodChunk.from_msg_gd(msg) == null:
				refused += 1
			if why != "":
				fails += 1
				if fails <= 8:
					print("DIFF res %d: %s  msg=%s" % [res, why, str(msg).substr(0, 240)])
	print("lod bodies: %d checked, %d refused" % [checked, refused])
	_bench()
	if fails > 0:
		print("FAIL: %d differences" % fails)
		quit(1)
		return
	print("PASS lod_decode_native_test")
	quit(0)


## "" when every path agrees with from_msg_gd; else what differs.
func _compare(msg: Dictionary) -> String:
	var want: Variant = LodData.LodChunk.from_msg_gd(msg)
	var direct: Variant = LodData.LodChunk.from_msg(msg)
	var why := _diff(want, direct, "from_msg native")
	if why != "":
		return why
	var pre := msg.duplicate()
	MessageDecode.prepare(pre, "lod")
	var had := pre.has("_lod")
	if had == (want == null):
		return "prepare's _lod %s for a body GDScript %s" % ["made" if had else "missing", "refuses" if want == null else "reads"]
	return _diff(want, LodData.LodChunk.from_msg(pre), "from_msg _lod")


func _diff(a: Variant, b: Variant, what: String) -> String:
	if (a == null) != (b == null):
		return "%s: %s vs %s" % [what, "null" if a == null else "chunk", "null" if b == null else "chunk"]
	if a == null:
		return ""
	if a.cx != b.cx or a.cy != b.cy or a.res != b.res or a.rev != b.rev:
		return "%s: header %s vs %s" % [what, [a.cx, a.cy, a.res, a.rev], [b.cx, b.cy, b.res, b.rev]]
	if typeof(b.tiles) != TYPE_PACKED_INT32_ARRAY or typeof(b.protos) != TYPE_PACKED_INT32_ARRAY \
			or typeof(b.flags) != TYPE_PACKED_BYTE_ARRAY:
		return "%s: list types" % what
	if a.tiles != b.tiles:
		return "%s: tiles" % what
	if a.protos != b.protos:
		return "%s: protos" % what
	if a.flags != b.flags:
		return "%s: flags" % what
	return ""


## A valid body at `res`; `kind` 0 float Arrays (JSON), 1 int Arrays, 2 PackedInt32Array, 3 PackedInt64Array.
func _body(res: int, kind: int) -> Dictionary:
	var side := 32 / res
	var total := side * side
	var tl: Array = []
	var left := total
	while left > 0:
		var c := mini(left, rng.randi_range(1, maxi(1, total / 3)) if rng.randf() < 0.7 else 1)
		tl.append(rng.randi_range(0, 300))
		tl.append(c)
		left -= c
	var el: Array = []
	left = total
	while left > 0:
		var c := mini(left, rng.randi_range(1, maxi(1, total / 4)) if rng.randf() < 0.6 else 1)
		el.append(0 if rng.randf() < 0.4 else rng.randi_range(1, 5000))
		el.append(rng.randi_range(0, 255))
		el.append(c)
		left -= c
	return {
		"t": "lod", "si": 1, "cx": rng.randi_range(-200, 200), "cy": rng.randi_range(-200, 200), "res": res,
		"rv": rng.randi_range(0, 9000), "tl": _as_kind(tl, kind), "el": _as_kind(el, kind),
	}


func _as_kind(list: Array, kind: int) -> Variant:
	if kind == 0:
		var f: Array = []
		for v: int in list:
			f.append(float(v))
		return f
	if kind == 1:
		return list.duplicate()
	if kind == 2:
		return PackedInt32Array(list)
	return PackedInt64Array(list)


func _mutate(src: Dictionary) -> Dictionary:
	var msg := src.duplicate(true)
	var key := "tl" if rng.randf() < 0.5 else "el"
	var list_v: Variant = msg[key]
	var arr: Array = Array(list_v) if not (list_v is Array) else (list_v as Array).duplicate()
	var packed := not (list_v is Array)
	var m := rng.randi_range(0, 13)
	var i := rng.randi_range(0, arr.size() - 1)
	match m:
		0:
			arr[i] = -1 - rng.randi_range(0, 3)
		1:
			arr[i] = int(arr[i]) + rng.randi_range(1, 40)
		2:
			arr[i] = maxi(0, int(arr[i]) - rng.randi_range(1, 3))
		3:
			arr[i] = float(arr[i]) + 0.5
		4:
			arr[i] = 0.25
		5:
			arr[i] = 256 if rng.randf() < 0.5 else 2147483648
		6:
			arr.pop_back()
		7:
			arr.append(1)
		8:
			arr.resize(0)
		9:
			arr[i] = 3000000000.0 if rng.randf() < 0.5 else -0.0
		_:
			# Not numbers: only an Array can hold them.
			var odd: Array = ["7", null, NAN, INF, true, [1], {"a": 1}]
			arr[i] = odd[rng.randi_range(0, odd.size() - 1)]
			packed = false
	if m == 13:
		msg[key] = {} if rng.randf() < 0.5 else "x"
		return msg
	if m == 12 and rng.randf() < 0.5:
		msg["res"] = [3, 0, 64, NAN, "8", -8][rng.randi_range(0, 5)]
	if packed and m <= 9:
		var all_int := true
		for v in arr:
			if not (v is int) or (list_v is PackedInt32Array and (int(v) > 2147483647 or int(v) < -2147483648)):
				all_int = false
		if all_int:
			msg[key] = PackedInt32Array(arr) if list_v is PackedInt32Array else PackedInt64Array(arr)
			return msg
	msg[key] = arr
	return msg


## The main thread's cost per `lod` message, before (from_msg_gd) and after (from_msg reading `_lod` made by
## MessageDecode.prepare on the parse thread), and the parse thread's own cost (prepare), on JSON-like bodies.
func _bench() -> void:
	for res: int in [2, 4, 8]:
		var bodies: Array = []
		for i in 400:
			bodies.append(_body(res, 0))
		var t0 := Time.get_ticks_usec()
		for msg: Dictionary in bodies:
			LodData.LodChunk.from_msg_gd(msg)
		var t_gd := Time.get_ticks_usec() - t0
		var prepared: Array = []
		t0 = Time.get_ticks_usec()
		for msg: Dictionary in bodies:
			var pre := msg.duplicate()
			MessageDecode.prepare(pre, "lod")
			prepared.append(pre)
		var t_prep := Time.get_ticks_usec() - t0
		t0 = Time.get_ticks_usec()
		for msg: Dictionary in prepared:
			LodData.LodChunk.from_msg(msg)
		var t_main := Time.get_ticks_usec() - t0
		var k := float(bodies.size())
		print("res %d (%d cells): main thread %.1f us/msg GDScript -> %.1f us/msg with _lod; parse thread %.1f us/msg (incl. a copy)" % [
			res, (32 / res) * (32 / res), t_gd / k, t_main / k, t_prep / k])
