extends Node
## The main menu's backdrop taken from the game being played (the Esc menu's "Use this view as the
## menu backdrop"): the square of chunks round the camera's spot and a few seconds of what moves
## there, recorded as the bridge sends them, in the same form as res://data/menu_world.json, so
## menu_background.gd draws it with the same loop. Each recording is one file (`path`, which the front
## end sets: a new one in user://backdrops/ each time, backdrop_list.gd); the camera's view and the
## name it is listed by go in the file with it. Nothing leaves the PC: it is the player's own world on
## their own disk.
##
## The bridge sends the prototypes once, at the handshake, so copies of those messages are kept as
## they arrive (cleared at each new handshake). record() then asks for every subscribed chunk again
## (`resync` `full: 0`, which also starts the belts' and movers' state over, so the belt lanes come
## whole) and keeps the square's chunks, entities and tiles and LIVE_SECONDS of the live updates.
##
## The live updates come for every subscribed chunk (21 x 21 of them): each is cut to the square as
## it arrives (cut_live: movers, hands and ground items by position, states by their entity's chunk,
## belt lanes by where their belt lies, a lane leading out of the square marked so as the bridge marks
## its own edge). The file is made and written on a worker thread (WorkerThreadPool): the JSON of a
## busy square took over a second on the main thread; `done` or `failed` comes from advance() once
## the write is over. Over MAX_BYTES the square is kept to 3 x 3 chunks, and over that still, to a
## still picture without the live updates.

signal done(path: String)
signal failed(reason: String)
signal progress(fraction: float)

const WireDecode := preload("res://scripts/net/wire_decode.gd")
const Wire := preload("res://scripts/util/wire.gd")
const PATH := "user://menu-backdrop.json.gz"
const VERSION := 1
const PROTO_KINDS := ["protos", "tprotos", "iprotos", "fprotos", "eprops"]
const LIVE := ["mv", "bs", "ih", "gi"]
const LIVE_SECONDS := 8.0
const TIMEOUT := 30.0
## The bridge ignores a `resync full 0` within 2 s of the last one: with no chunk of the square this
## long after record()'s resync, it is sent once more (the cooldown is over by then).
const RETRY_AFTER := 2.5
## The menu world's square: 5 x 5 chunks (menu_background.gd's view_radius).
const RADIUS := 2
## A busier square than this (raw JSON) is kept to 3 x 3 chunks.
const MAX_BYTES := 8 * 1024 * 1024
## A `bs`'s lists of a lane read by its key: how many numbers a record.
const WIDTHS := {"dl": 1, "pc": 5, "pu": 3, "ew": 4, "sh": 2}

## Where the snapshot goes (the front end sets it for each recording; the tests use their own).
var path := PATH
## main.gd's world: a chunk the bridge answers with `same` (the client's copy still holds) is taken
## from its kept messages. Untyped; null in the tests.
var world = null

var _protos: Array = []
var _recording := false
var _elapsed := 0.0
## _elapsed when the first chunk of the square came after the resync: the recording's 0.
var _started := -1.0
var _center := Vector2.ZERO
var _info := {}
## [chunk Vector2i or null, message with dt], in order.
var _kept: Array = []
## Chunk -> [ents parts expected, ents parts got] (-1 expected: not sent yet).
var _parts := {}
var _puppet := 0
## record()'s resync was sent again (once only).
var _retried := false
## Time.get_ticks_msec() at record(): the timeout holds by the wall clock too, whatever the frames' deltas.
var _started_ms := 0
## Lane key -> [the chunk its belt is in, the chunk past its exit end], from every `lm` heard.
var _lanes := {}
## Entity unit -> its chunk, from the kept `ents`.
var _units := {}
## The write's WorkerThreadPool task (-1: none) and what it hands back (its own Dictionary, every key
## there from the start: the worker only assigns, never inserts; the main thread doesn't touch it meanwhile).
var _task := -1
var _job := {}
## cancel() during the write (main thread only, never in `_job`, which the worker holds): no signal at its end.
var _write_cancelled := false


func _ready() -> void:
	Bridge.welcomed.connect(_on_welcome)
	Bridge.message_received.connect(on_message)


func _on_welcome(_msg: Dictionary) -> void:
	_protos.clear()
	if _recording:
		_fail("the game started over while recording")


## Whether a recording runs or its file is being written (the button stays greyed till `done`).
func recording() -> bool:
	return _recording or _task >= 0


func writing() -> bool:
	return _task >= 0


## Starts a recording round `center` (tiles). `camera`: camera_dict(); `info` goes into the file
## as it is ("save", "name", "puppet": the player's own character, left out of the movers).
func record(center: Vector2, camera: Dictionary, info := {}) -> bool:
	if _recording or _task >= 0 or _protos.is_empty():
		return false
	_recording = true
	_elapsed = 0.0
	_started = -1.0
	_retried = false
	_started_ms = Time.get_ticks_msec()
	_center = center
	_info = info.duplicate()
	_info["camera"] = camera
	_puppet = int(info.get("puppet", 0))
	_kept = []
	_lanes = {}
	_units = {}
	_parts.clear()
	var c0 := chunk_of(center)
	for dx in range(-RADIUS, RADIUS + 1):
		for dy in range(-RADIUS, RADIUS + 1):
			_parts[c0 + Vector2i(dx, dy)] = [-1, 0]
	Bridge.send({"t": "resync", "full": 0})
	return true


## (While the file is being written it can't be stopped: it is written, but no signal comes.)
func cancel() -> void:
	_recording = false
	_kept = []
	if _task >= 0:
		_write_cancelled = true


func _exit_tree() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _process(delta: float) -> void:
	advance(delta)


## The recording's clock (the tests move it on themselves).
func advance(delta: float) -> void:
	if _task >= 0:
		_poll_write()
	if not _recording:
		return
	_elapsed += delta
	var live := (_elapsed - _started) / LIVE_SECONDS if _started >= 0.0 else 0.0
	# (Up to 0.99 here: 1.0 is the write's start, from _finish; the progress box greys its Cancel then.)
	progress.emit(clampf(0.1 + 0.89 * minf(live, 1.0), 0.0, 0.99))
	if _started < 0.0 and not _retried and _elapsed >= RETRY_AFTER:
		_retried = true
		Bridge.send({"t": "resync", "full": 0})
	if _started >= 0.0 and _elapsed - _started >= LIVE_SECONDS and _square_complete():
		_finish()
	elif _elapsed >= TIMEOUT or Time.get_ticks_msec() - _started_ms >= int(TIMEOUT * 1000.0) + 5000:
		_fail("the chunks didn't all come in %d s" % int(TIMEOUT))


func on_message(msg: Dictionary) -> void:
	var t := str(msg.get("t", ""))
	if PROTO_KINDS.has(t):
		_protos.append(msg)
		return
	if not _recording:
		return
	match t:
		"chunk":
			var c := Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0)))
			if not _parts.has(c):
				return
			if _started < 0.0:
				_started = _elapsed
			var messages: Array = [msg]
			if msg.has("same"):
				messages = _kept_by_world(msg)
				if messages.is_empty():
					return
			# Sent again: the newer replaces what was kept.
			_kept = _kept.filter(func(e: Array) -> bool: return not (e[0] is Vector2i and e[0] == c))
			_parts[c] = [0 if bool(msg.get("none", false)) else int(messages[0].get("parts", 0)), 0]
			var got: Array = _parts[c]
			for m: Dictionary in messages:
				if str(m.get("t", "")) == "ents":
					got[1] = int(got[1]) + 1
				_keep(c, m)
		"ents":
			var c := Vector2i(int(msg.get("cx", 0)), int(msg.get("cy", 0)))
			var got: Array = _parts.get(c, [-1, 0])
			if int(got[0]) >= 0:
				got[1] = int(got[1]) + 1
				_keep(c, msg)
		"tiles":
			if _started >= 0.0:
				var l := _square_tiles(msg.get("l"), _center, RADIUS)
				if not l.is_empty():
					_keep(null, {"t": "tiles", "l": l})
		"st":
			if _started >= 0.0:
				_keep(null, msg)  # (cut when the file is made: its entities may come later)
		_:
			if t == "bs" or t == "ih":
				msg = WireDecode.plain(msg)  # (a binary part's packed lists as JSON's: kept and cut as they are)
				note_lanes(_lanes, msg)
			if LIVE.has(t) and _started >= 0.0 and _elapsed - _started <= LIVE_SECONDS:
				_keep(null, cut_live(msg, RADIUS, chunk_of(_center), _lanes, _units, _puppet))


func _keep(c: Variant, msg: Dictionary) -> void:
	msg = WireDecode.plain(msg)  # (a binary frame's packed lists and ents records as their JSON has them)
	var copy := msg.duplicate()
	copy.erase("_tiles")  # (the chunk's tiles as the client decoded them, message_decode.gd: the menu reads `tiles`)
	copy["dt"] = snappedf(maxf(0.0, _elapsed - maxf(_started, 0.0)), 0.001)
	_kept.append([c, copy])
	if c is Vector2i and str(msg.get("t", "")) == "ents":
		for e in Wire.array(msg.get("e")):
			if e is Array and (e as Array).size() > 0 and int(e[0]) != 0:
				_units[int(e[0])] = c


## The chunk's messages as the world keeps them (world.gd _cache), for a `same`.
func _kept_by_world(msg: Dictionary) -> Array:
	if world == null:
		return []
	var entry: Dictionary = world._cache.get(Vector3i(int(msg.get("rs", -1)), int(msg.get("cx", 0)), int(msg.get("cy", 0))), {})
	if entry.is_empty() or int(entry.get("rv", -1)) != int(msg.get("same", -2)):
		return []
	return (entry["msgs"] as Array).duplicate()


func _square_complete() -> bool:
	for c in _parts:
		var p: Array = _parts[c]
		if int(p[0]) < 0 or int(p[1]) < int(p[0]):
			return false
	return true


## The recording's data handed to a worker thread as it is (the recorder starts afresh): the file is
## made, cut to 3 x 3 or to a still picture when too big, and written there; advance() hears the end.
func _finish() -> void:
	_recording = false
	_job = {"kept": _kept, "protos": _protos.duplicate(), "lanes": _lanes, "units": _units, "center": _center,
		"info": _info.duplicate(), "puppet": _puppet, "path": path, "ok": false, "count": 0, "raw": 0}
	_write_cancelled = false
	_kept = []
	_lanes = {}
	_units = {}
	_task = WorkerThreadPool.add_task(_encode.bind(_job), false, "menu backdrop")
	progress.emit(1.0)


## On the worker: touches only `job` (assigns its keys, inserts none), which the main thread leaves alone
## till the task is over.
func _encode(job: Dictionary) -> void:
	var data := build(job, RADIUS, true)
	var text := JSON.stringify(data)
	if text.length() > MAX_BYTES:
		print("backdrop: %d KB for 5 x 5 chunks, kept to 3 x 3" % (text.length() / 1024))
		data = build(job, 1, true)
		text = JSON.stringify(data)
	if text.length() > MAX_BYTES:
		print("backdrop: still %d KB for 3 x 3 chunks: kept as a still picture, without the live updates" % (text.length() / 1024))
		data = build(job, 1, false)
		text = JSON.stringify(data)
	job["kept"] = []
	job["raw"] = text.length()
	job["count"] = (data["messages"] as Array).size()
	job["ok"] = write(str(job["path"]), data, text)


## The write's end, heard on the main thread: `done` or `failed`, once.
func _poll_write() -> void:
	if not WorkerThreadPool.is_task_completed(_task):
		return
	WorkerThreadPool.wait_for_task_completion(_task)
	_task = -1
	_end_write()


func _end_write() -> void:
	var job := _job
	_job = {}
	var cancelled := _write_cancelled
	_write_cancelled = false
	if cancelled:
		print("backdrop: the recording was written after it was cancelled; no signal")
	elif job.get("ok", false):
		print("backdrop: recorded %d messages round %s (%d KB of JSON)" % [int(job["count"]), job["center"], int(job["raw"]) / 1024])
		done.emit(str(job["path"]))
	else:
		print("backdrop: not recorded: %s couldn't be written" % job["path"])
		failed.emit("the file couldn't be written")


## Blocks till the write is over and gives its signal (the tests; never in a frame of the game).
func wait_written() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_end_write()


func _fail(reason: String) -> void:
	_recording = false
	_kept = []
	print("backdrop: not recorded: %s" % reason)
	failed.emit(reason)


## The file's contents for what is kept now (see build()).
func snapshot(radius: int, live := true) -> Dictionary:
	return build({"kept": _kept, "protos": _protos, "lanes": _lanes, "units": _units, "center": _center, "info": _info,
		"puppet": _puppet}, radius, live)


## The file's contents: the prototypes, then what was kept within `radius` chunks of the centre
## (`live` false: without the live updates, a still picture). Static: it runs on the worker.
static func build(job: Dictionary, radius: int, live: bool) -> Dictionary:
	var messages: Array = []
	for m: Dictionary in job["protos"]:
		var copy := m.duplicate()
		copy["dt"] = 0.0
		messages.append(copy)
	var center: Vector2 = job["center"]
	var c0 := chunk_of(center)
	for e: Array in job["kept"]:
		var m: Dictionary = e[1]
		var t := str(m.get("t", ""))
		if e[0] is Vector2i:
			var d: Vector2i = (e[0] as Vector2i) - c0
			if maxi(absi(d.x), absi(d.y)) > radius:
				continue
		elif t == "tiles" and radius < RADIUS:
			var l := _square_tiles(m.get("l"), center, radius)
			if l.is_empty():
				continue
			m = m.duplicate()
			m["l"] = l
		elif LIVE.has(t):
			if not live:
				continue
			if radius < RADIUS:
				m = cut_live(m, radius, c0, job["lanes"], job["units"], int(job.get("puppet", 0)))
		elif t == "st":
			m = cut_live(m, radius, c0, job["lanes"], job["units"], 0)
		messages.append(m)
	var data := {"v": VERSION, "center": [center.x, center.y], "taken": int(Time.get_unix_time_from_system()), "messages": messages}
	var info: Dictionary = job["info"]
	for key in info:
		data[key] = info[key]
	return data


## The chunk of a map position in 1/256 tile.
static func _chunk_256(x: int, y: int) -> Vector2i:
	return Vector2i(floori(x / 8192.0), floori(y / 8192.0))


static func _near(c: Vector2i, c0: Vector2i, radius: int) -> bool:
	return maxi(absi(c.x - c0.x), absi(c.y - c0.y)) <= radius


## Notes where each lane of a `bs`'s `lm` lies ([its chunk (the line's middle point), the chunk half
## a tile past its exit end]), in or out of the square, as `lanes` keeps them for cut_live().
static func note_lanes(lanes: Dictionary, msg: Dictionary) -> void:
	var a := Wire.array(msg.get("lm"))
	for i in range(0, a.size() - 11, 12):
		var x0 := int(a[i + 4])
		var y0 := int(a[i + 5])
		var xm := int(a[i + 6])
		var ym := int(a[i + 7])
		var out := Vector2(x0 - xm, y0 - ym)
		out = out.normalized() * 128.0 if out.length() > 0.0 else Vector2.ZERO
		lanes[int(a[i])] = [_chunk_256(xm, ym), _chunk_256(x0 + int(out.x), y0 + int(out.y))]


## A live update (`mv`, `ih`, `gi`, `bs`, `st`) cut to the chunks within `radius` of `c0`: a new
## message, the one given untouched. Movers, inserter hands and ground items by their positions
## (delta-coded `mv` and `ih` written out plain; `puppet`'s mover left out); states by their
## entity's chunk (`units`, from the kept `ents`); belt lanes by their belt's chunk (`lanes`, from
## note_lanes()), each list of a lane (`lm`, `sl`, `dl`, `pc`, `pu`, `ew`, `sh`) together, with the
## quality names (`qu`) of the items kept and the switched-off belts (`of`) of the belts kept. A kept
## lane whose items go on into a lane outside is marked as leading out (`lm` next -1, or minus the key
## it goes into), as the bridge marks the lanes at its own square's edge.
static func cut_live(msg: Dictionary, radius: int, c0: Vector2i, lanes: Dictionary, units: Dictionary, puppet := 0) -> Dictionary:
	var t := str(msg.get("t", ""))
	var copy := msg.duplicate()
	match t:
		"mv":
			var deltas := int(msg.get("z", 0)) == 1
			var sums := [0, 0, 0, 0]
			var out: Array = []
			for rec in Wire.array(WireDecode.mv_records(msg)):  # (a binary frame's packed records, whole)
				if not (rec is Array and (rec as Array).size() >= 4):
					continue
				var r: Array = (rec as Array).duplicate()
				for i in 4:
					sums[i] = int(sums[i]) + int(r[i]) if deltas else int(r[i])
					r[i] = sums[i]
				if (puppet == 0 or int(r[0]) != puppet) and _near(_chunk_256(int(r[2]), int(r[3])), c0, radius):
					out.append(r)
			copy.erase("z")
			copy["l"] = out
		"ih":
			var deltas := int(msg.get("z", 0)) == 1
			var v := [0, 0, 0, 0]
			var l := Wire.array(msg.get("l"))
			var out: Array = []
			var i := 0
			while i + 3 < l.size():
				for j in 4:
					v[j] = int(v[j]) + int(l[i + j]) if deltas else int(l[i + j])
				if _near(_chunk_256(int(v[1]), int(v[2])), c0, radius):
					out.append_array(v)
				i += 4
			copy.erase("z")
			copy["l"] = out
		"gi":
			var l := Wire.array(msg.get("l"))
			var out: Array = []
			for i in range(0, l.size() - 2, 3):
				if _near(_chunk_256(int(l[i + 1]), int(l[i + 2])), c0, radius):
					out.append_array([l[i], l[i + 1], l[i + 2]])
			copy["l"] = out
		"st":
			for key: String in ["l", "lc", "ao"]:
				if msg.has(key):
					copy[key] = _cut_pairs(Wire.array(msg[key]), func(u: int) -> bool: return units.has(u) and _near(units[u], c0, radius))
		"bs":
			_cut_belts(msg, copy, radius, c0, lanes, units)
	return copy


## [unit, value, ...] keeping the pairs whose unit `keep` says.
static func _cut_pairs(l: Array, keep: Callable) -> Array:
	var out: Array = []
	for i in range(0, l.size() - 1, 2):
		if keep.call(int(l[i])):
			out.append_array([l[i], l[i + 1]])
	return out


static func _cut_belts(msg: Dictionary, copy: Dictionary, radius: int, c0: Vector2i, lanes: Dictionary, units: Dictionary) -> void:
	var inside := func(key: int) -> bool:
		return lanes.has(key) and _near((lanes[key] as Array)[0], c0, radius)
	if msg.has("lm"):
		var a := Wire.array(msg["lm"])
		var out: Array = []
		for i in range(0, a.size() - 11, 12):
			var key := int(a[i])
			if not inside.call(key):
				continue
			var lane := a.slice(i, i + 12)
			var nxt := int(lane[11])
			if nxt >= 0:
				# (Where its items go on: the lane it names, else past its exit end.)
				var to: Vector2i = (lanes[nxt] as Array)[0] if nxt > 0 and lanes.has(nxt) else (lanes[key] as Array)[1]
				if not _near(to, c0, radius):
					lane[11] = -nxt if nxt > 0 else -1
			out.append_array(lane)
		copy["lm"] = out
	var uids := {}
	if msg.has("sl"):
		var a := Wire.array(msg["sl"])
		var out: Array = []
		var i := 0
		while i + 2 < a.size():
			var n := clampi(int(a[i + 2]), 0, (a.size() - i - 3) / 4)
			if inside.call(int(a[i])):
				out.append_array(a.slice(i, i + 3 + n * 4))
				for j in n:
					uids[int(a[i + 3 + j * 4])] = true
			i += 3 + n * 4
		copy["sl"] = out
	for key: String in WIDTHS:
		if not msg.has(key):
			continue
		var width: int = WIDTHS[key]
		var a := Wire.array(msg[key])
		var out: Array = []
		for i in range(0, a.size() - width + 1, width):
			if inside.call(int(a[i])):
				out.append_array(a.slice(i, i + width))
		copy[key] = out
	if msg.has("qu"):
		copy["qu"] = _cut_pairs(Wire.array(msg["qu"]), func(u: int) -> bool: return uids.has(u))
	if msg.has("of"):
		var belt := func(u: int) -> bool:
			if units.has(u):
				return _near(units[u], c0, radius)
			for line in range(1, 9):
				if inside.call(u * 8 + line):
					return true
			return false
		copy["of"] = _cut_pairs(Wire.array(msg["of"]), belt)


static func chunk_of(tile: Vector2) -> Vector2i:
	return Vector2i(floori(tile.x / 32.0), floori(tile.y / 32.0))


## A `tiles` list's [x, y, id] within `radius` chunks of `center`.
static func _square_tiles(list: Variant, center: Vector2, radius: int) -> Array:
	var out: Array = []
	if not (list is Array):
		return out
	var l: Array = list
	var c0 := chunk_of(center)
	var i := 0
	while i + 2 < l.size():
		var d := chunk_of(Vector2(float(l[i]), float(l[i + 1]))) - c0
		if maxi(absi(d.x), absi(d.y)) <= radius:
			out.append_array([l[i], l[i + 1], l[i + 2]])
		i += 3
	return out


## An `mv` without `unit`'s record. A delta-coded one (z 1) is written out plain: its records are
## differences from the one before, so one can't just be left out.
static func without_unit(msg: Dictionary, unit: int) -> Dictionary:
	var list = msg.get("l")
	if unit == 0 or not (list is Array):
		return msg
	var deltas := int(msg.get("z", 0)) == 1
	var out: Array = []
	var sums := [0, 0, 0, 0]
	for rec in list:
		if not (rec is Array and (rec as Array).size() >= 4):
			continue
		var r: Array = (rec as Array).duplicate()
		for i in 4:
			sums[i] = int(sums[i]) + int(r[i]) if deltas else int(r[i])
			r[i] = sums[i]
		if int(r[0]) != unit:
			out.append(r)
	var copy := msg.duplicate()
	copy.erase("z")
	copy["l"] = out
	return copy


## The camera's view as the file keeps it.
static func camera_dict(camera: Camera3D) -> Dictionary:
	var t := camera.global_transform
	var xf: Array = []
	for v: Vector3 in [t.basis.x, t.basis.y, t.basis.z, t.origin]:
		xf.append_array([v.x, v.y, v.z])
	return {"xf": xf, "fov": camera.fov, "proj": "orthogonal" if camera.projection == Camera3D.PROJECTION_ORTHOGONAL else "perspective",
		"size": camera.size}


## camera_dict()'s transform, or null when it isn't one.
static func camera_transform(d: Variant) -> Variant:
	if not (d is Dictionary) or not ((d as Dictionary).get("xf") is Array) or ((d as Dictionary)["xf"] as Array).size() != 12:
		return null
	var n: Array = (d as Dictionary)["xf"]
	return Transform3D(Basis(_vec(n, 0), _vec(n, 3), _vec(n, 6)), _vec(n, 9))


static func _vec(n: Array, i: int) -> Vector3:
	return Vector3(float(n[i]), float(n[i + 1]), float(n[i + 2]))


## Writes `data` whole (`text`: its JSON when already made): to a .tmp first (one left over from
## before removed), then the old file removed and the .tmp renamed onto its name; when the rename
## fails (Windows: the old file still held open), the .tmp is copied over it instead. Never waits.
static func write(file: String, data: Dictionary, text := "") -> bool:
	var tmp := file + ".tmp"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)
	var f := FileAccess.open_compressed(tmp, FileAccess.WRITE, FileAccess.COMPRESSION_GZIP)
	if f == null:
		return false
	f.store_string(text if text != "" else JSON.stringify(data))
	f.close()
	if FileAccess.file_exists(file):
		DirAccess.remove_absolute(file)
	if DirAccess.rename_absolute(tmp, file) == OK:
		return true
	var copied := DirAccess.copy_absolute(tmp, file) == OK
	DirAccess.remove_absolute(tmp)
	return copied


## The snapshot in `file`, or {} when it is missing, unreadable, of another version or without a
## single chunk (a hand-edited file: the built-in world is drawn then, not an empty scene).
static func read(file: String) -> Dictionary:
	if not FileAccess.file_exists(file):
		return {}
	var f := FileAccess.open_compressed(file, FileAccess.READ, FileAccess.COMPRESSION_GZIP)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary) or int((parsed as Dictionary).get("v", 0)) != VERSION or not ((parsed as Dictionary).get("messages") is Array):
		return {}
	for m in (parsed as Dictionary)["messages"]:
		if m is Dictionary and str((m as Dictionary).get("t", "")) == "chunk":
			return parsed
	return {}
