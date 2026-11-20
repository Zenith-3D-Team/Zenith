extends RefCounted
## The log of automatic performance holds (the owner: "a warning icon ... showing any hold 60 ups or
## performance automatic downgrading of settings ... clickable to show a log"). The UPS governor
## (ups_governor.gd) notes each setting it holds back, one entry per knob whose value changed, with
## why; its work budget, Automatic moving belt items (belt_lanes.gd) and the bridge's belt square are
## noted too, but only light no icon (`lights` false): they move all the time by design. perf_warning.gd
## shows it. Static, no node: nothing costs anything until something is noted. Cleared for a new game.
##
## An entry: {"source", "key", "label" (a LABELS-style text with one %s for "from → to"), "from", "to"
## (texts), "why", "lights", "msec", "time" (the PC's time of day), and once it ends "ended_msec",
## "ended_time", "ended" (why: "restored, back at 60 for 30 s" or "then 96")}. At most one entry of a
## source and key is open (not ended) at a time.

const CAP := 200
## The icon stays this long after the last hold that lit it ends, so it doesn't blink.
const LINGER_MSEC := 10000

static var entries: Array = []
static var _listeners: Array = []
## The clock (tests set it; -1: Time.get_ticks_msec()).
static var test_msec := -1
## When the last lighting entry ended (msec), -1 never.
static var last_lit_end := -1
## Bumped on every change, so a reader (the open panel) can tell whether there is anything new to draw.
static var version := 0


static func now() -> int:
	return test_msec if test_msec >= 0 else Time.get_ticks_msec()


## A hold: closes the open entry of the same source and key ("then <to>") and opens a new one.
static func note(source: String, key: String, label: String, from: String, to: String, why: String, lights := true) -> Dictionary:
	var open := find_open(source, key)
	if not open.is_empty():
		_end(open, "then " + to)
	var e := {"source": source, "key": key, "label": label, "from": from, "to": to, "why": why, "lights": lights,
		"msec": now(), "time": Time.get_time_string_from_system()}
	entries.append(e)
	_trim()
	_changed()
	return e


## The open entry of a source and key went lower (one entry for a run of cuts: the lowest kept).
static func lower(source: String, key: String, to: String) -> void:
	var open := find_open(source, key)
	if open.is_empty() or str(open["to"]) == to:
		return
	open["to"] = to
	_changed()


## The setting is back: the open entry of the source and key ends.
static func restore(source: String, key: String, why: String) -> void:
	finish(source, key, "restored" + (", " + why if why != "" else ""))


## The open entry of the source and key ends for `why` without the setting coming back (a ceiling that
## no longer holds anything back).
static func finish(source: String, key: String, why: String) -> void:
	var open := find_open(source, key)
	if open.is_empty():
		return
	_end(open, why)
	_changed()


static func find_open(source: String, key: String) -> Dictionary:
	for i in range(entries.size() - 1, -1, -1):
		var e: Dictionary = entries[i]
		if e["source"] == source and e["key"] == key:
			return {} if e.has("ended_msec") else e
	return {}


static func is_open(source: String, key: String) -> bool:
	return not find_open(source, key).is_empty()


## The entries still held that light the icon.
static func active() -> Array:
	var out: Array = []
	for e: Dictionary in entries:
		if e["lights"] and not e.has("ended_msec"):
			out.append(e)
	return out


## Whether the icon shows: a hold now, or one ended under LINGER_MSEC ago.
static func lit() -> bool:
	return not active().is_empty() or (last_lit_end >= 0 and now() - last_lit_end < LINGER_MSEC)


## "entity distance 192 → 128".
static func what(e: Dictionary) -> String:
	return str(e["label"]) % ("%s → %s" % [e["from"], e["to"]])


## One line of text per entry, newest first (the panel's Copy).
static func text() -> String:
	var lines: Array = []
	for i in range(entries.size() - 1, -1, -1):
		lines.append(line(entries[i]))
	return "\n".join(lines)


static func line(e: Dictionary) -> String:
	var s := "%s  %s (%s)" % [e["time"], what(e), e["why"]]
	if not e["lights"]:
		s += " [log only]"
	if e.has("ended_msec"):
		s += ": %s at %s, after %s" % [e["ended"], e["ended_time"], span(int(e["ended_msec"]) - int(e["msec"]))]
	else:
		s += ": held"
	return s


static func span(msec: int) -> String:
	var s := maxi(0, msec / 1000)
	if s < 60:
		return "%d s" % s
	if s < 3600:
		return "%d min" % (s / 60)
	return "%d h %d min" % [s / 3600, (s / 60) % 60]


## A new game: nothing from the last one.
static func clear() -> void:
	entries.clear()
	last_lit_end = -1
	_changed()


static func listen(f: Callable) -> void:
	if not _listeners.has(f):
		_listeners.append(f)


static func unlisten(f: Callable) -> void:
	_listeners.erase(f)


static func _end(e: Dictionary, why: String) -> void:
	e["ended_msec"] = now()
	e["ended_time"] = Time.get_time_string_from_system()
	e["ended"] = why
	if e["lights"]:
		last_lit_end = now()


## Over CAP: the oldest ended entry goes first, else the oldest.
static func _trim() -> void:
	while entries.size() > CAP:
		var drop := 0
		for i in entries.size():
			if (entries[i] as Dictionary).has("ended_msec"):
				drop = i
				break
		entries.remove_at(drop)


static func _changed() -> void:
	version += 1
	for f in _listeners.duplicate():
		if f.is_valid():
			f.call()
		else:
			_listeners.erase(f)
