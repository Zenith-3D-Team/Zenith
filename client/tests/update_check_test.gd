extends SceneTree
## update_check.gd's version comparison, release reading and "Don't show again" logic (no network).
##
##   godot --headless --audio-driver Dummy --path client --log-file <abs> -s res://tests/update_check_test.gd

const UpdateCheck := preload("res://scripts/menu/update_check.gd")

var fails := 0


func _ok(cond: bool, what: String) -> void:
	if not cond:
		fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	_ok(UpdateCheck.parse_version("v0.3.1") == [0, 3, 1], "parse v-prefix")
	_ok(UpdateCheck.parse_version("0.3.1-beta") == [0, 3, 1], "parse suffix")
	_ok(UpdateCheck.parse_version("junk").is_empty(), "parse junk")
	_ok(UpdateCheck.compare("0.10.0", "0.9.9") == 1, "numeric, not text")
	_ok(UpdateCheck.compare("0.3", "0.3.0") == 0, "missing part is 0")
	_ok(UpdateCheck.compare("v0.2.1", "0.3.0") == -1, "older")
	_ok(UpdateCheck.compare("x", "0.3.0") == 0, "unreadable is equal")
	_ok(UpdateCheck.should_offer("0.3.1", "0.3.0", ""), "newer offered")
	_ok(not UpdateCheck.should_offer("0.3.0", "0.3.0", ""), "same not offered")
	_ok(not UpdateCheck.should_offer("0.2.9", "0.3.0", ""), "older not offered")
	_ok(not UpdateCheck.should_offer("", "0.3.0", ""), "nothing seen")
	_ok(not UpdateCheck.should_offer("0.3.1", "0.3.0", "0.3.1"), "don't show again holds")
	_ok(UpdateCheck.should_offer("0.3.2", "0.3.0", "0.3.1"), "a newer one than the skipped shows")
	_ok(UpdateCheck.due(1000, 0), "never asked: due")
	_ok(not UpdateCheck.due(1000 + 3600, 1000), "1 h: not due")
	_ok(UpdateCheck.due(1000 + 6 * 3600, 1000), "6 h: due")
	_ok(UpdateCheck.due(500, 1000), "clock back: due")
	_ok(UpdateCheck.safe_url("https://github.com/Zenith-3D-Team/Zenith/releases/tag/v1") == "https://github.com/Zenith-3D-Team/Zenith/releases/tag/v1", "own url kept")
	_ok(UpdateCheck.safe_url("https://evil.example/x") == UpdateCheck.RELEASES_URL, "foreign url replaced")
	var good := '{"tag_name":"v0.3.1","html_url":"https://github.com/Zenith-3D-Team/Zenith/releases/tag/v0.3.1"}'.to_utf8_buffer()
	_ok(UpdateCheck.parse_release(200, good).get("version", "") == "0.3.1", "release read")
	_ok(UpdateCheck.parse_release(403, good).is_empty(), "rate limit silent")
	_ok(UpdateCheck.parse_release(200, '{"tag_name":"v9","prerelease":true}'.to_utf8_buffer()).is_empty(), "pre-release skipped")
	_ok(UpdateCheck.parse_release(200, '{"tag_name":"v9","draft":true}'.to_utf8_buffer()).is_empty(), "draft skipped")
	_ok(UpdateCheck.parse_release(200, "not json".to_utf8_buffer()).is_empty(), "bad json silent")
	# The popup's auto-check path: a skipped version stays quiet, a newer one doesn't
	_ok(not UpdateCheck.should_offer("0.3.1", "0.3.0", "0.3.1"), "auto stays quiet for the skipped version")
	_ok(UpdateCheck.should_offer("0.3.1", "0.3.0", "0.3.0"), "an older skip doesn't hide it")
	_ok(not UpdateCheck.auto_on(), "auto check is off by default")
	print("update_check_test: %s" % ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	quit(0 if fails == 0 else 1)
