extends Node
## "A new version is available" (main menu). One HTTPS GET to GitHub's public "latest release" page
## of Zenith's own repository. Nothing is requested unless the player clicks "Check for updates" at the
## main menu's bottom left (check_now) or has turned "Auto check on open" on (start_auto: when the menu
## opens, at most once in 6 hours, silent unless a newer version exists). Nothing is sent but the
## request itself (the Accept header and "User-Agent: Zenith/<version>"): no id, no query string,
## nothing about the player. Nothing is downloaded or installed: the popup (front_end.gd) only opens
## the releases page in the browser. `--update-check=off`: no button, no request; `--update-check=test`:
## the button and popup work with a made-up newer version and no request. The dev channel and a
## headless run have no button and ask nothing.

const Settings := preload("res://scripts/menu/settings.gd")
const Switches := preload("res://scripts/switches.gd")

const URL := "https://api.github.com/repos/Zenith-3D-Team/Zenith/releases/latest"
const RELEASES_URL := "https://github.com/Zenith-3D-Team/Zenith/releases/latest"
const SAFE_PREFIX := "https://github.com/Zenith-3D-Team/Zenith/"
const INTERVAL_SEC := 6 * 3600
const TIMEOUT_SEC := 8.0

## An answer: kind is "newer" (version, url set), "latest" or "failed"; `manual` is a click's.
signal done(kind: String, version: String, current: String, url: String, manual: bool)

var busy := false
var _http: HTTPRequest


## "v0.3.1", "0.3.1-beta" -> [0, 3, 1]; anything unreadable -> [].
static func parse_version(text: String) -> Array[int]:
	var out: Array[int] = []
	var t := text.strip_edges().trim_prefix("v").trim_prefix("V")
	t = t.get_slice("-", 0).get_slice("+", 0)
	if t == "":
		return out
	for part in t.split("."):
		if not part.is_valid_int():
			return [] as Array[int]
		out.append(int(part))
	return out


## Part by part (missing parts count as 0): -1, 0 or 1; 0 also when either side is unreadable.
static func compare(a: String, b: String) -> int:
	var pa := parse_version(a)
	var pb := parse_version(b)
	if pa.is_empty() or pb.is_empty():
		return 0
	for i in range(maxi(pa.size(), pb.size())):
		var x := pa[i] if i < pa.size() else 0
		var y := pb[i] if i < pb.size() else 0
		if x != y:
			return 1 if x > y else -1
	return 0


## The popup shows: `latest` is newer than this build and than the version "Don't show again" was
## pressed for.
static func should_offer(latest: String, current: String, skipped: String) -> bool:
	if latest == "" or compare(latest, current) <= 0:
		return false
	return skipped == "" or compare(latest, skipped) > 0


## Time for a request: the last one is 6 hours back (or the clock went backwards).
static func due(now: int, last: int) -> bool:
	return last <= 0 or last > now or now - last >= INTERVAL_SEC


## The page the Download button opens: the release's own page when it is on Zenith's repository.
static func safe_url(url: String) -> String:
	return url if url.begins_with(SAFE_PREFIX) else RELEASES_URL


## The version and page from GitHub's answer: {"version", "url"}, or {} for a draft, a pre-release, a
## failed request or anything unreadable.
static func parse_release(code: int, body: PackedByteArray) -> Dictionary:
	if code != 200:
		return {}
	var json := JSON.new()  # (not parse_string: that logs an engine error for a bad body)
	if json.parse(body.get_string_from_utf8()) != OK or not json.data is Dictionary:
		return {}
	var d: Dictionary = json.data
	if bool(d.get("draft", false)) or bool(d.get("prerelease", false)):
		return {}
	var tag := str(d.get("tag_name", ""))
	if parse_version(tag).is_empty():
		return {}
	return {"version": tag.trim_prefix("v").trim_prefix("V"), "url": safe_url(str(d.get("html_url", "")))}


## The button and the checks exist at all: public channel, a window, not `--update-check=off`.
static func enabled() -> bool:
	return Switches.value("--update-check") != "off" and not Settings.dev_tools() and DisplayServer.get_name() != "headless"


## "Auto check on open" (the one setting, in the popup and in Settings > Interface).
static func auto_on() -> bool:
	return bool(Settings.get_value("interface", "update_check"))


## "Don't show again" for this version.
static func skip(version: String) -> void:
	Settings.set_value("interface", "update_skip", version)


static func current_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0"))


## The click: asks now (never held back by the 6 hours, only by one request at a time).
func check_now() -> void:
	if busy:
		return
	var current := current_version()
	if Switches.value("--update-check") == "test":
		busy = true
		_fake.call_deferred(current, true)
		return
	_ask(current, true)


## The menu opened: asks if "Auto check on open" is on and 6 hours have passed; silent unless newer.
func start_auto() -> void:
	if busy or not enabled() or not auto_on() or Switches.value("--update-check") == "test":
		return
	var current := current_version()
	var now := int(Time.get_unix_time_from_system())
	if not due(now, int(Settings.get_value("interface", "update_checked_at"))):
		# A newer version seen within the 6 hours still shows its popup, from what was kept.
		var seen := str(Settings.get_value("interface", "update_seen"))
		var skipped := str(Settings.get_value("interface", "update_skip"))
		if should_offer(seen, current, skipped):
			done.emit.call_deferred("newer", seen, current, safe_url(str(Settings.get_value("interface", "update_seen_url"))), false)
		return
	_ask(current, false)


func _fake(current: String, manual: bool) -> void:
	busy = false
	var p := parse_version(current)
	p.resize(3)
	p[2] = int(p[2]) + 1
	done.emit("newer", "%d.%d.%d" % [p[0], p[1], p[2]], current, RELEASES_URL, manual)


func _ask(current: String, manual: bool) -> void:
	if not enabled():
		done.emit.call_deferred("failed", "", current, "", manual)
		return
	busy = true
	# Noted before the request: a failing automatic one waits the 6 hours too.
	Settings.set_value("interface", "update_checked_at", int(Time.get_unix_time_from_system()))
	_http = HTTPRequest.new()
	_http.timeout = TIMEOUT_SEC
	add_child(_http)
	_http.request_completed.connect(_on_done.bind(current, manual))
	var err := _http.request(URL, PackedStringArray(["Accept: application/vnd.github+json", "User-Agent: Zenith/" + current]))
	if err != OK:
		print("[update] check not made (error %d)" % err)
		busy = false
		done.emit.call_deferred("failed", "", current, "", manual)


func _on_done(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, current: String, manual: bool) -> void:
	busy = false
	_http.queue_free()
	_http = null
	var release := parse_release(code, body) if result == HTTPRequest.RESULT_SUCCESS else {}
	if release.is_empty():
		print("[update] no usable answer (result %d, HTTP %d)" % [result, code])
		done.emit("failed", "", current, "", manual)
		return
	var version := str(release["version"])
	var url := str(release["url"])
	Settings.set_value("interface", "update_seen", version)
	Settings.set_value("interface", "update_seen_url", url)
	if compare(version, current) > 0:
		# An automatic check stays quiet for a version "Don't show again" was pressed for.
		if manual or should_offer(version, current, str(Settings.get_value("interface", "update_skip"))):
			done.emit("newer", version, current, url, manual)
	elif manual:
		done.emit("latest", version, current, "", manual)
