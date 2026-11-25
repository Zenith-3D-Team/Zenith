extends Node
## Permanent regression tests for client bridge responsiveness:
## 1) PRIORITY_COMMANDS wire command coverage
## 2) _route / _drain fast-lane priority ordering (_me -> _prio -> _live -> _belt -> bulk), _hold_kinds, and server_tick stability
## 3) Single-part (cq/al/sky) and multi-part (mv/ih/gi/en/hp) snapshot coalescing without dropping ie/rb/bs/reliable or incomplete ticks
## 4) Selective NACK recovery (gap send, out-of-order retransmit hit, NACK_MAX_GAP fallback, 250ms timeout + late drop grace, welcome/disconnect clear, --nack=off, --coalesce-updates=off)
## 5) WorldMirror _dirty_live preemption, synchronous <512 build, --fast-edit-rebuild=off, and >128 near-first _apply_states_waiting()
## 6) belt_items.gd out-of-order near_spool protection (k0 < k square/period and per-lane lm/sl/dl/of guards)
## 7) --resync-guard: no handshake-stall resync while `ready` waits in the queue, full resyncs back off and
##    wait for their welcome, the old session's messages dropped at a new welcome (the second PC's resync loop)

const BridgeScript := preload("res://scripts/net/bridge.gd")
const BeltItemsScript := preload("res://scripts/world/belt_items.gd")
const WorldMirror := preload("res://scripts/world/world.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const TestEnv := preload("res://tests/test_env.gd")

var passes := 0
var fails := 0


func check(cond: bool, msg: String) -> void:
	if cond:
		passes += 1
	else:
		fails += 1
		print("FAIL: %s" % msg)


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	TestEnv.isolate("bridge_queue_stress_test")
	var cap_was: Variant = Bridge.capture
	Bridge.capture = []

	_test_priority_commands_and_flags()
	if "--verify-off" in OS.get_cmdline_user_args():
		_test_cli_off_args()
		Bridge.capture = cap_was
		TestEnv.clean()
		await get_tree().process_frame
		print("bridge_queue_stress_test (--verify-off): %d passed, %d failed" % [passes, fails])
		print("FAILS: %d" % fails)
		get_tree().quit(1 if fails > 0 else 0)
		return
	_test_route_and_drain_order()
	_test_coalescing_single_and_multi()
	_test_selective_nack_and_off_flags()
	await _test_world_dirty_live_and_states_slicing()
	_test_belt_items_near_spool_guard()
	_test_resync_guard()

	Bridge.capture = cap_was
	TestEnv.clean()
	await get_tree().process_frame
	print("bridge_queue_stress_test: %d passed, %d failed" % [passes, fails])
	print("FAILS: %d" % fails)
	get_tree().quit(1 if fails > 0 else 0)


func _make_bridge() -> Node:
	var b: Node = BridgeScript.new()
	add_child(b)
	b.capture = []
	b.priority_queue = true
	b.coalesce_updates = true
	b.nack_enabled = true
	b.belt_messages_first = true
	b.connected = true
	b.world_ready = true
	b._seq_connected = true
	b._seq_world_ready = true
	b._expected_r = 1
	return b


func _parsed_capture(b: Node) -> Array:
	var out: Array = []
	var cap: Array = b.capture
	for raw in cap:
		var parsed: Variant = JSON.parse_string(str(raw))
		if parsed is Dictionary:
			out.append(parsed)
	return out


func _test_priority_commands_and_flags() -> void:
	var required := [
		"walk", "drive", "enter", "mine", "mine_stop", "mine_at",
		"build", "blueprint", "rails", "tile", "tile_mine", "rotate", "flip",
		"open", "close", "take", "put", "move", "xfer", "fast", "sort", "inv_filter",
		"drop", "pickup", "pickup_stop", "shoot", "gun", "throw",
		"craft", "cancel_craft", "wire", "wire_clear", "decon", "upgrade",
		"copy", "paste", "paste_settings", "undo", "redo",
		"qb_set", "qb_sel", "qb_page",
		"set_recipe", "set_bar", "set_inserter", "set_splitter", "set_switch",
		"set_panel", "set_cb", "set_cc", "set_color", "set_lamp",
		"set_desc", "set_speaker", "set_pump", "set_targets", "set_vehicle",
		"set_artillery", "set_requests", "set_storage_filter", "set_chest_logistics",
		"set_char_requests", "set_section",
		"train_go", "train_mode", "train_temp", "set_stop", "set_interrupts", "set_train_group",
		"repair", "pause", "focus", "sub", "bre", "nack",
	]
	var missing: Array = []
	for cmd in required:
		if not BridgeScript.PRIORITY_COMMANDS.has(cmd):
			missing.append(cmd)
	var non_prio_ok := not BridgeScript.PRIORITY_COMMANDS.has("hello") \
		and not BridgeScript.PRIORITY_COMMANDS.has("map") \
		and not BridgeScript.PRIORITY_COMMANDS.has("lod_sub") \
		and not BridgeScript.PRIORITY_COMMANDS.has("resync")
	check(missing.is_empty() and non_prio_ok,
		"PRIORITY_COMMANDS includes all required wire actions (%s missing) and excludes bulk commands (%s)" % [missing, non_prio_ok])

	# Verify CLI default flags match expectations in headless test (no --*-off passed).
	var b: Node = _make_bridge()
	if not ("--verify-off" in OS.get_cmdline_user_args()):
		check(b.coalesce_updates and b.nack_enabled and WorldMirror.fast_edit_rebuild,
			"default flags enabled: coalesce_updates=%s nack=%s fast_edit_rebuild=%s"
			% [b.coalesce_updates, b.nack_enabled, WorldMirror.fast_edit_rebuild])
	b.queue_free()


func _test_cli_off_args() -> void:
	var b: Node = BridgeScript.new()
	add_child(b)
	check(not b.coalesce_updates and not b.nack_enabled and not WorldMirror.fast_edit_rebuild,
		"CLI off flags parsed: coalesce_updates=%s nack_enabled=%s fast_edit_rebuild=%s"
		% [b.coalesce_updates, b.nack_enabled, WorldMirror.fast_edit_rebuild])
	b.queue_free()


func _int_array(raw: Variant) -> Array:
	var out: Array = []
	if raw is Array:
		for v in raw as Array:
			out.append(int(v))
	return out


func _test_route_and_drain_order() -> void:
	var b: Node = _make_bridge()
	b.server_tick = 50
	var order: Array = []
	var delay_done := false
	var on_msg := func(m: Dictionary) -> void:
		var t := str(m.get("t", ""))
		order.append(t)
		if t == "chunk" and not delay_done:
			delay_done = true
			OS.delay_usec(2000)
	b.message_received.connect(on_msg)

	# Route bulk chunk(0,0), same-chunk add(0,0), belt bs, live ie/rb/pj/afx, prio far add & inv, and me.
	var msgs := [
		{"t": "chunk", "r": 1, "k": 51, "cx": 0, "cy": 0},
		{"t": "add", "r": 2, "k": 51, "e": [1001, 1, 128, 128, 0]},
		{"t": "bs", "k": 52, "part": 1, "parts": 1, "lm": []},
		{"t": "ie", "k": 53, "l": [1, 10, 53, 0, 0, 0, 0, 0, 0]},
		{"t": "rb", "k": 54, "part": 1, "parts": 1, "u": []},
		{"t": "pj", "k": 55},
		{"t": "afx", "k": 56},
		{"t": "add", "r": 3, "k": 51, "e": [1002, 1, 6 * 32 * 256, 0, 0]},
		{"t": "inv", "r": 4, "k": 51, "l": []},
		{"t": "me", "k": 57},
	]
	b._route(msgs, PackedInt32Array(), Time.get_ticks_usec())
	check(b._me_waiting.size() == 1 and b._prio_waiting.size() == 2 and b._live_waiting.size() == 3
		and b._belt_waiting.size() == 1 and b._waiting.size() == 3,
		"route buckets with pending chunk: me=%d prio=%d live=%d belt=%d bulk=%d"
		% [b._me_waiting.size(), b._prio_waiting.size(), b._live_waiting.size(), b._belt_waiting.size(), b._waiting.size()])

	b._drain()
	var want := ["me", "add", "inv", "rb", "pj", "afx", "bs", "chunk", "add", "ie"]
	check(order == want, "drain order keeps ie behind pending chunk in _waiting: got %s" % [order])
	check(int(b.stats["me_first"]) == 1 and int(b.stats["prio_first"]) == 2
		and int(b.stats["live_first"]) == 3 and int(b.stats["belt_first"]) == 1,
		"drain stats counters match: %s" % [b.stats])

	# When _chunk_waiting is empty (steady play), ie uses _live_waiting ahead of bs.
	order.clear()
	check(b._chunk_waiting.is_empty(), "_chunk_waiting is empty after bulk drain")
	b._route([
		{"t": "bs", "k": 58, "part": 1, "parts": 1, "lm": []},
		{"t": "ie", "k": 58, "l": [1, 10, 58, 0, 0, 0, 0, 0, 0]},
	], PackedInt32Array(), Time.get_ticks_usec())
	check(b._live_waiting.size() == 1 and b._belt_waiting.size() == 1 and b._waiting.is_empty(),
		"steady play routes ie via _live_waiting when _chunk_waiting is empty (live=%d wait=%d)"
		% [b._live_waiting.size(), b._waiting.size()])
	b._drain()
	check(order == ["ie", "bs"], "steady play drains ie ahead of bs: %s" % [order])

	# _drain_live does not regress server_tick when live_waiting has smaller k, and updates newest_tick.
	b.server_tick = 900
	b.newest_tick = 900
	b._route([{"t": "ie", "k": 850, "l": []}, {"t": "ie", "k": 920, "l": []}], PackedInt32Array(), Time.get_ticks_usec())
	b._drain_live()
	check(b.server_tick == 900 and b.newest_tick == 920,
		"_drain_live preserves bulk server_tick (%d) while tracking newest_tick (%d)" % [b.server_tick, b.newest_tick])

	# _hold_kinds respected by _drain_live and _drain_belts.
	order.clear()
	b.hold_types({"ie": true, "bs": true})
	b._route([{"t": "ie", "k": 921, "l": []}, {"t": "rb", "k": 921, "part": 1, "parts": 1, "u": []}, {"t": "bs", "k": 921, "part": 1, "parts": 1}],
		PackedInt32Array(), Time.get_ticks_usec())
	b._drain()
	check(order == ["rb"] and b.held_count() == 2,
		"hold_types holds ie and bs during _drain_live/_drain_belts while emitting unheld rb: order=%s held=%d" % [order, b.held_count()])
	b.hold_types({})
	b._clear_held()

	b.queue_free()


func _test_coalescing_single_and_multi() -> void:
	var b: Node = _make_bridge()
	var seen: Array = []
	var on_msg := func(m: Dictionary) -> void:
		seen.append([str(m.get("t", "")), int(m.get("k", -1)), int(m.get("part", 0)), str(m.get("tag", ""))])
	b.message_received.connect(on_msg)

	# 1. Single-part coalescing (cq in prio, al & sky in bulk) + reliable message preserved + barrier isolation:
	var msgs := [
		{"t": "cq", "k": 10, "tag": "cq1"},
		{"t": "cq", "k": 11, "tag": "cq2"},
		{"t": "cq", "k": 12, "tag": "cq3"},
		{"t": "al", "k": 10, "tag": "al1"},
		{"t": "al", "k": 11, "tag": "al2"},
		{"t": "al", "r": 1, "k": 12, "tag": "al_rel"},
		{"t": "sky", "k": 10, "tag": "sky1"},
		{"t": "sky", "k": 11, "tag": "sky2"},
		# Multi-part mv in _live_waiting: tick 100 complete (2/2), tick 101 complete (2/2), tick 102 INCOMPLETE (1/2)!
		{"t": "mv", "k": 100, "part": 1, "parts": 2, "tag": "mv100_1"},
		{"t": "mv", "k": 100, "part": 2, "parts": 2, "tag": "mv100_2"},
		{"t": "mv", "k": 101, "part": 1, "parts": 2, "tag": "mv101_1"},
		{"t": "mv", "k": 101, "part": 2, "parts": 2, "tag": "mv101_2"},
		{"t": "mv", "k": 102, "part": 1, "parts": 2, "tag": "mv102_1"},
		# Non-coalesceable live events & belts must NEVER be coalesced:
		{"t": "ie", "k": 100, "l": [], "tag": "ie1"},
		{"t": "ie", "k": 101, "l": [], "tag": "ie2"},
		{"t": "rb", "k": 100, "part": 1, "parts": 1, "u": [], "tag": "rb1"},
		{"t": "rb", "k": 101, "part": 1, "parts": 1, "u": [], "tag": "rb2"},
		{"t": "bs", "k": 100, "part": 1, "parts": 1, "tag": "bs1"},
		{"t": "bs", "k": 101, "part": 1, "parts": 1, "tag": "bs2"},
		# Multi-part ih in _waiting: tick 50 complete (2/2) coalesced, tick 51 complete (2/2) kept.
		{"t": "ih", "k": 50, "part": 1, "parts": 2, "tag": "ih50_1"},
		{"t": "ih", "k": 50, "part": 2, "parts": 2, "tag": "ih50_2"},
		{"t": "ih", "k": 51, "part": 1, "parts": 2, "tag": "ih51_1"},
		{"t": "ih", "k": 51, "part": 2, "parts": 2, "tag": "ih51_2"},
	]
	b._route(msgs, PackedInt32Array(), Time.get_ticks_usec())
	for _i in 4:
		if b.waiting_count() == 0 and b._live_waiting.is_empty() and b._prio_waiting.is_empty():
			break
		b._drain()

	var tags: Array = []
	for row in seen:
		tags.append(str((row as Array)[3]))
	check("cq3" in tags and "cq1" not in tags and "cq2" not in tags,
		"single-part cq coalesced to newest (%s)" % [tags])
	check("al2" in tags and "al1" not in tags and "al_rel" in tags,
		"al coalesced older unreliable while preserving reliable r message (%s)" % [tags])
	check("sky2" in tags and "sky1" not in tags,
		"sky coalesced to newest (%s)" % [tags])
	check("mv100_1" not in tags and "mv100_2" not in tags
		and "mv101_1" in tags and "mv101_2" in tags and "mv102_1" in tags,
		"multi-part mv drops older complete tick 100, keeps newest complete 101 and incomplete 102 (%s)" % [tags])
	check("ih50_1" not in tags and "ih50_2" not in tags and "ih51_1" in tags and "ih51_2" in tags,
		"multi-part ih coalesced older complete tick 50 and kept 51 (%s)" % [tags])
	check("ie1" in tags and "ie2" in tags and "rb1" in tags and "rb2" in tags and "bs1" in tags and "bs2" in tags,
		"ie, rb, bs never coalesced (%s)" % [tags])
	check(int(b.stats["coalesced"]) == 8,
		"coalesced counter == 8 (got %d)" % int(b.stats["coalesced"]))

	# 2. _routed_out still decrements _chunk_waiting/_belts_behind on coalesced _waiting msgs, and PRIO_BARRIERS isolate coalescing:
	seen.clear()
	b.capture = []
	b._route([
		{"t": "chunk", "r": 2, "k": 199, "cx": 3, "cy": 3},
		{"t": "al", "k": 200, "tag": "pre_bar"},
		{"t": "al", "k": 201, "tag": "pre_bar_keep"},
		{"t": "surface", "r": 3, "k": 201, "tag": "bar"},
		{"t": "bs", "k": 201, "part": 1, "parts": 1, "tag": "bs_behind"},
		{"t": "ents", "r": 4, "k": 201, "cx": 3, "cy": 3, "part": 1, "parts": 1},
		{"t": "al", "k": 202, "tag": "post_bar"},
	], PackedInt32Array(), Time.get_ticks_usec())
	b._drain()
	var bar_tags: Array = []
	for row in seen:
		bar_tags.append(str((row as Array)[3]))
	check("pre_bar" not in bar_tags and "pre_bar_keep" in bar_tags and "bar" in bar_tags and "post_bar" in bar_tags
		and b._chunk_waiting.is_empty() and b._belts_behind == 0,
		"PRIO_BARRIERS stop coalescing across surface barrier and _routed_out clears chunk/belt tracking: %s cw=%s bb=%d"
		% [bar_tags, b._chunk_waiting, b._belts_behind])

	# 3. --coalesce-updates=off disables live fast-lane and coalescing:
	b.queue_free()
	b = _make_bridge()
	b.coalesce_updates = false
	var off_seen: Array = []
	var on_off := func(m: Dictionary) -> void:
		off_seen.append(str(m.get("t", "")))
	b.message_received.connect(on_off)
	b._route([
		{"t": "ie", "k": 1, "l": []},
		{"t": "cq", "k": 1},
		{"t": "cq", "k": 2},
		{"t": "al", "k": 1},
		{"t": "al", "k": 2},
	], PackedInt32Array(), Time.get_ticks_usec())
	check(b._live_waiting.is_empty() and b._waiting.size() == 3,
		"--coalesce-updates=off keeps ie/al in bulk _waiting (live=%d, wait=%d)" % [b._live_waiting.size(), b._waiting.size()])
	b._drain()
	check(int(b.stats["coalesced"]) == 0 and off_seen.size() == 5,
		"--coalesce-updates=off performs zero coalescing (%d, emitted=%d)" % [int(b.stats["coalesced"]), off_seen.size()])
	b.queue_free()


func _test_selective_nack_and_off_flags() -> void:
	# 1. _route NACK gap send, out-of-order retransmit hit, welcome clear:
	var b: Node = _make_bridge()
	var got_r: Array = []
	var on_msg := func(m: Dictionary) -> void:
		if m.has("r"):
			got_r.append(int(m["r"]))
	b.message_received.connect(on_msg)
	b._expected_r = 10

	b._route([{"t": "inv", "r": 13, "l": []}], PackedInt32Array(), Time.get_ticks_usec())
	var sent: Array = _parsed_capture(b)
	var nack_pkt: Dictionary = {}
	for s_msg in sent:
		if str((s_msg as Dictionary).get("t", "")) == "nack":
			nack_pkt = s_msg
	check(str(nack_pkt.get("t", "")) == "nack" and _int_array(nack_pkt.get("r", [])) == [10, 11, 12]
		and b._expected_r == 10 and b._reorder.size() == 1 and b._nack_pending.size() == 3
		and int(b.stats["gaps"]) == 1 and int(b.stats["nacks_sent"]) == 1 and b._pending_resync == 0,
		"NACK sent for missing [10,11,12] without resync: pkt=%s pending=%s" % [nack_pkt, b._nack_pending.keys()])

	# Retransmit missing r in out-of-order sequence:
	b._route([
		{"t": "inv", "r": 11, "l": []},
		{"t": "inv", "r": 10, "l": []},
		{"t": "inv", "r": 12, "l": []},
	], PackedInt32Array(), Time.get_ticks_usec())
	b._drain()
	check(int(b.stats["nack_hits"]) == 3 and b._nack_pending.is_empty() and b._pending_resync == 0
		and got_r == [10, 11, 12, 13] and b._reorder.is_empty() and b._expected_r == 14,
		"NACK hits process retransmitted reliable messages in order and clear _nack_pending: hits=%d got=%s" % [int(b.stats["nack_hits"]), got_r])

	# 2. Direct receive() (non-seq_checked _handle) path also sends NACK and handles hit:
	b.capture = []
	b._expected_r = 20
	b.receive(JSON.stringify({"t": "inv", "r": 22, "l": []}).to_utf8_buffer())
	var rec_sent: Array = _parsed_capture(b)
	var has_nack2 := false
	for s_msg in rec_sent:
		if str((s_msg as Dictionary).get("t", "")) == "nack" and _int_array((s_msg as Dictionary).get("r", [])) == [20, 21]:
			has_nack2 = true
	b.receive(JSON.stringify({"t": "inv", "r": 20, "l": []}).to_utf8_buffer())
	b.receive(JSON.stringify({"t": "inv", "r": 21, "l": []}).to_utf8_buffer())
	check(has_nack2 and b._nack_pending.is_empty() and int(b.stats["nack_hits"]) == 5,
		"direct receive() handles NACK gap and retransmit hits cleanly (has_nack=%s, hits=%d)" % [has_nack2, int(b.stats["nack_hits"])])

	# 3. Gap > NACK_MAX_GAP (64) falls back to request_resync instead of sending NACK:
	b.capture = []
	b._expected_r = 30
	var nacks_before: int = int(b.stats["nacks_sent"])
	b._route([{"t": "inv", "r": 30 + BridgeScript.NACK_MAX_GAP + 1, "l": []}], PackedInt32Array(), Time.get_ticks_usec())
	check(int(b.stats["nacks_sent"]) == nacks_before and b._pending_resync == 1 and b._nack_pending.is_empty(),
		"gap > NACK_MAX_GAP (%d) falls back to chunk resync (pending_resync=%d)" % [BridgeScript.NACK_MAX_GAP, b._pending_resync])

	# 4. 250ms timeout expires _nack_pending, falls back to chunk resync, and drops late retransmits without full_resyncs:
	b._pending_resync = 0
	b._nack_pending[99] = Time.get_ticks_msec() - (BridgeScript.NACK_TIMEOUT_MSEC + 50)
	b._last_resync_msec = Time.get_ticks_msec() - 10000
	b.resync_chunks = func() -> Array: return [[0, 0]]
	b.capture = []
	b._check_nack_timeouts()
	if b._pending_resync > 0 and b.connected:
		b._send_resync()
	var to_sent: Array = _parsed_capture(b)
	var sent_resync := false
	for s_msg in to_sent:
		if str((s_msg as Dictionary).get("t", "")) == "resync":
			sent_resync = true
	check(b._nack_pending.is_empty() and b._nack_expired.has(99) and int(b.stats["nack_timeouts"]) == 1 and sent_resync,
		"NACK timeout (>250ms) moves r to _nack_expired, increments nack_timeouts, and triggers chunk resync (%s)" % [to_sent])

	b._pending_resync = 0
	b._expected_r = 105
	var full_before: int = int(b.stats["full_resyncs"])
	var late_before: int = int(b.stats["nack_late_drops"])
	var prio_before: int = b._prio_waiting.size()
	var wait_before: int = b._waiting.size()
	b._route([{"t": "inv", "r": 99, "l": []}], PackedInt32Array(), Time.get_ticks_usec())
	check(not b._nack_expired.has(99) and int(b.stats["nack_late_drops"]) == late_before + 1
		and b._pending_resync == 0 and int(b.stats["full_resyncs"]) == full_before
		and b._prio_waiting.size() == prio_before and b._waiting.size() == wait_before,
		"late NACK retransmit (>250ms via _route) drops cleanly without full resync (late_drops=%d pending=%d full=%d)"
		% [int(b.stats["nack_late_drops"]), b._pending_resync, int(b.stats["full_resyncs"])])

	# Direct receive() path also drops expired late NACK without full resync:
	b._nack_pending[101] = Time.get_ticks_msec() - (BridgeScript.NACK_TIMEOUT_MSEC + 50)
	b._check_nack_timeouts()
	b._pending_resync = 0
	b._expected_r = 105
	b.receive(JSON.stringify({"t": "inv", "r": 101, "l": []}).to_utf8_buffer())
	check(not b._nack_expired.has(101) and int(b.stats["nack_late_drops"]) == late_before + 2
		and b._pending_resync == 0 and int(b.stats["full_resyncs"]) == full_before,
		"late NACK retransmit (>250ms via receive) drops cleanly without full resync (late_drops=%d pending=%d)"
		% [int(b.stats["nack_late_drops"]), b._pending_resync])

	# Aged-out (>NACK_EXPIRED_GRACE_MSEC) entries sweep out and genuine old r still triggers full resync:
	b._nack_expired[102] = Time.get_ticks_msec() - (BridgeScript.NACK_EXPIRED_GRACE_MSEC + 100)
	b._check_nack_timeouts()
	check(not b._nack_expired.has(102), "_check_nack_timeouts sweeps aged-out _nack_expired entries")
	b._pending_resync = 0
	b._route([{"t": "inv", "r": 102, "l": []}], PackedInt32Array(), Time.get_ticks_usec())
	check(b._pending_resync == 2, "untracked stale r < _expected_r still requests full resync (pending_resync=%d)" % b._pending_resync)

	# 5. welcome and disconnect_from clear _nack_pending, _nack_expired, and _live_waiting:
	b._nack_pending[150] = Time.get_ticks_msec()
	b._nack_expired[151] = Time.get_ticks_msec()
	b._live_waiting.append({"t": "ie"})
	b._route([{"t": "welcome", "r": 1, "v": 1, "k": 1}], PackedInt32Array(), Time.get_ticks_usec())
	check(b._nack_pending.is_empty() and b._nack_expired.is_empty() and b._live_waiting.is_empty(),
		"welcome clears _nack_pending, _nack_expired, and _live_waiting")
	b._nack_expired[152] = Time.get_ticks_msec()
	b.disconnect_from()
	check(b._nack_expired.is_empty() and int(b.stats["nack_late_drops"]) == 0,
		"disconnect_from clears _nack_expired and resets nack_late_drops")

	_test_reorder_and_delta_order()

	# 6. --nack=off disables NACK and falls back to resync on small gap:
	b.queue_free()
	b = _make_bridge()
	b.nack_enabled = false
	b._expected_r = 10
	b._route([{"t": "inv", "r": 12, "l": []}], PackedInt32Array(), Time.get_ticks_usec())
	check(int(b.stats["nacks_sent"]) == 0 and b._nack_pending.is_empty() and b._pending_resync == 1,
		"--nack=off skips NACK and requests resync on gap of 2 (pending_resync=%d)" % b._pending_resync)
	b.queue_free()


func _make_world() -> WorldMirror:
	var w := WorldMirror.new()
	add_child(w)
	w.set_process(false)
	w.surface_index = 1
	w.protos.add_tiles([[0, "grass-1", 80, 120, 60], [1, "stone-path", 100, 100, 100]])
	w.protos.add_entities([[1, "wooden-chest", "container", -0.5, -0.5, 0.5, 0.5, 100, 100, 100, 1, 1]])
	return w


func _attach_chunk(w: WorldMirror, c: Vector2i) -> ChunkView:
	var cv := ChunkView.new()
	cv.coord = c
	cv.loaded = true
	w.chunks[c] = cv
	w.add_child(cv)
	return cv


func _test_world_dirty_live_and_states_slicing() -> void:
	var fast_was: bool = WorldMirror.fast_edit_rebuild
	var no_dead_was: bool = FrameBudget.test_no_deadline
	var shared_was: bool = FrameBudget.shared
	WorldMirror.fast_edit_rebuild = true
	FrameBudget.test_no_deadline = true
	FrameBudget.shared = false
	FrameBudget.reset()

	var w := _make_world()
	# Background chunks (10,0)..(19,0) vs farther live chunk (20,0):
	var cv_bg := _attach_chunk(w, Vector2i(10, 0))
	var cv_live := _attach_chunk(w, Vector2i(20, 0))
	# Add enough entities to bg (50 > WORKER_MIN_INSTANCES=48) and 1 entity to live (<512).
	for i in 50:
		w._add([4000 + i, 1, (10 * 32 + 1 + (i % 10)) * 256, (1 + (i / 10)) * 256, 0])
	w._dirty.clear()
	w._dirty_live.clear()
	w._dirty[Vector2i(10, 0)] = true

	# Live add on (20,0) marks _dirty_live[(20,0)]:
	w.handle({"t": "add", "e": [5001, 1, (20 * 32 + 2) * 256, 2 * 256, 0]})
	check(w._dirty_live.has(Vector2i(20, 0)) and w._dirty.has(Vector2i(20, 0)),
		"live add marks _dirty_live for chunk (20,0)")

	# During _replaying, live add does NOT mark _dirty_live:
	w._replaying = true
	w.handle({"t": "add", "e": [5002, 1, (10 * 32 + 15) * 256, 2 * 256, 0]})
	w._replaying = false
	check(not w._dirty_live.has(Vector2i(10, 0)),
		"replaying add does not mark _dirty_live")

	# Live upd, del mark _dirty_live; live tiles mark _dirty_terrain:
	var cv_0 := _attach_chunk(w, Vector2i(0, 0))
	cv_0.tile_ids.resize(32 * 32)
	w._dirty_live.erase(Vector2i(20, 0))
	w.handle({"t": "tiles", "l": [1, 1, 1]})
	w.handle({"t": "upd", "e": [4000, 1, (10 * 32 + 1) * 256, 1 * 256, 4]})
	w.handle({"t": "del", "u": 5001})
	check(w._dirty_terrain.has(Vector2i(0, 0)) and w._dirty_live.has(Vector2i(10, 0)) and w._dirty_live.has(Vector2i(20, 0)),
		"live tiles mark _dirty_terrain and upd/del mark _dirty_live")
	w._dirty_terrain.erase(Vector2i(0, 0))
	w._dirty_live.erase(Vector2i(10, 0))
	w._dirty_live.erase(Vector2i(20, 0))

	# _rebuild_dirty preempts farther _dirty_live (20,0) ahead of closer background _dirty chunks (1,0)..(12,0),
	# and builds (20,0) (60 instances >= WORKER_MIN_INSTANCES=48 and <512) synchronously without worker _prep_jobs!
	for cx in range(1, 13):
		if not w.chunks.has(Vector2i(cx, 0)):
			_attach_chunk(w, Vector2i(cx, 0))
		w._dirty[Vector2i(cx, 0)] = true
	for i in 60:
		w._add([5100 + i, 1, (20 * 32 + 1 + (i % 10)) * 256, (1 + (i / 10)) * 256, 0])
	w._dirty_live.clear()
	w._dirty_live[Vector2i(20, 0)] = true
	w._dirty[Vector2i(20, 0)] = true
	var worker_was: bool = ChunkView.chunk_mm_worker
	ChunkView.chunk_mm_worker = true
	w._rebuild_dirty()
	ChunkView.chunk_mm_worker = worker_was
	check(not w._dirty_live.has(Vector2i(20, 0)) and not w._dirty.has(Vector2i(20, 0))
		and not w._prep_jobs.has(Vector2i(20, 0)) and w._dirty.size() >= 3,
		"_rebuild_dirty preempts closer background chunks (left=%d) and builds live (20,0) synchronously"
		% w._dirty.size())
	# Wait for any worker job on (10,0) before freeing w:
	for k in w._prep_jobs.keys():
		var job: ChunkView.ChunkPrepJob = w._prep_jobs[k]
		if job.task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(job.task_id)
	w._prep_jobs.clear()

	# >128 near-first state slicing (_apply_states_waiting):
	# Place 130 outer entities in chunk (5,0) and 20 near entities in chunks (0,0) & (2,0).
	var cv_2 := _attach_chunk(w, Vector2i(2, 0))
	var cv_5 := _attach_chunk(w, Vector2i(5, 0))
	w.set_focus(Vector2.ZERO)
	w.focus_radius = 256
	var st_list: Array = []
	for i in 130:
		var uid := 6000 + i
		w._add([uid, 1, (5 * 32 + 2) * 256, 2 * 256, 0])
		st_list.append(uid)
		st_list.append(1)
	for i in 18:
		var uid := 7000 + i
		var cx := 0 if i < 9 else 2
		w._add([uid, 1, (cx * 32 + 2) * 256, 2 * 256, 0])
		st_list.append(uid)
		st_list.append(1)
	# Append two consecutive state changes for near unit 7018 (0 then 1) to verify per-unit order preservation:
	w._add([7018, 1, 4 * 256, 4 * 256, 0])
	st_list.append(7018)
	st_list.append(0)
	st_list.append(7018)
	st_list.append(1)
	w.working.clear()
	w._st_lists.clear()
	w._st_at = 0
	w._st_i = 0
	w._st_prio_lists = 0
	w.handle({"t": "st", "l": st_list})
	w._apply_states_waiting(20)
	var near_all_applied := true
	for i in 18:
		if int(w.working.get(7000 + i, -1)) != 1:
			near_all_applied = false
	var outer_first_untouched := int(w.working.get(6000, -1)) == -1
	var order_preserved := int(w.working.get(7018, -1)) == 1
	check(near_all_applied and order_preserved and outer_first_untouched,
		">128 near-first _apply_states_waiting applies near (<=2) first (%s), preserves arrival order (7018=%s), defers outer (6000=%s)"
		% [near_all_applied, w.working.get(7018, -1), w.working.get(6000, -1)])

	# --fast-edit-rebuild=off disables _dirty_live marking and >128 state reordering:
	WorldMirror.fast_edit_rebuild = false
	w._dirty_live.clear()
	w.handle({"t": "add", "e": [5099, 1, (20 * 32 + 5) * 256, 5 * 256, 0]})
	w.working.clear()
	w._st_lists.clear()
	w._st_at = 0
	w._st_i = 0
	w._st_prio_lists = 0
	w.handle({"t": "st", "l": st_list})
	w._apply_states_waiting(25)
	check(w._dirty_live.is_empty() and int(w.working.get(6000, -1)) == 1 and int(w.working.get(7000, -1)) == -1,
		"--fast-edit-rebuild=off skips _dirty_live and applies states in strict FIFO order (6000=%s, 7000=%s)"
		% [w.working.get(6000, -1), w.working.get(7000, -1)])

	w.queue_free()
	await get_tree().process_frame
	WorldMirror.fast_edit_rebuild = fast_was
	FrameBudget.test_no_deadline = no_dead_was
	FrameBudget.shared = shared_was
	FrameBudget.reset()


func _bs_lane(key: int, kind: int, length: int, step: int, ex: float, ey: float, nx: float, ny: float, nxt := 0) -> Array:
	var cx: float = (ex + nx) * 0.5
	var cy: float = (ey + ny) * 0.5
	return [key, kind, length, step, roundi(ex * 256.0), roundi(ey * 256.0), roundi(cx * 256.0), roundi(cy * 256.0),
		roundi(nx * 256.0), roundi(ny * 256.0), 0, nxt]


func _sim_item_map(sim: RefCounted) -> Dictionary:
	var st: Array = sim.items_state()
	var uids: PackedInt64Array = st[0]
	var keys: PackedInt64Array = st[1]
	var pos: PackedInt32Array = st[2]
	var out: Dictionary = {}
	for i in uids.size():
		out[int(uids[i])] = [int(keys[i]), int(pos[i])]
	return out


func _test_belt_items_near_spool_guard() -> void:
	var was_gd: bool = BeltItemsScript.State.force_gd
	var was_lat_nat: bool = BeltItemsScript.State.lattice_native
	var was_dec: bool = BeltItemsScript.Job.native_decode
	var was_cull: bool = BeltItemsScript.Job.view_cull
	BeltItemsScript.Job.view_cull = false

	var has_native: bool = ClassDB.class_exists("BeltSimNative") and ClassDB.class_exists("BeltLatticeNative")
	var modes: Array = [true, false] if has_native else [false]
	for ndec_val in modes:
		var ndec: bool = bool(ndec_val)
		BeltItemsScript.State.force_gd = not has_native
		BeltItemsScript.State.lattice_native = has_native
		BeltItemsScript.Job.native_decode = ndec
		var items := BeltItemsScript.new()
		items._sync = true
		add_child(items)
		items.set_process(false)

		# 1. Newer live near_spool tick k=1000 arrives first:
		var lm_new: Array = _bs_lane(81, 1, 256, 8, 11.0, 10.25, 10.0, 10.25)
		items.handle({
			"t": "bs", "k": 1000, "p": 6, "w": 100, "fx": 5 * 256, "fy": 10 * 256, "fr": 48,
			"lm": lm_new, "sl": [81, 1000, 1, 901, 1, 64, 1], "of": [10, 1],
		})
		items._process(1.0 / 60.0)
		check(items._state._square_tick == 1000 and items._state.period == 6
			and items._state.square == Vector3(5.0, 10.0, 48.0)
			and int(items._state._lane_tick.get(81, -1)) == 1000
			and int(items._state._off_tick.get(10, -1)) == 1000,
			"belt_items (ndec=%s): newer near_spool tick 1000 initializes square/period/_lane_tick/_off_tick" % str(ndec))

		# 2. Older queued tick k0=990 arrives afterward: must NOT rewind square/period or lane 81 / unit 10,
		# while still applying unaffected lane 89 (unit 11):
		var lm_old: Array = []
		lm_old.append_array(_bs_lane(81, 1, 256, 8, 99.0, 99.0, 98.0, 99.0))
		lm_old.append_array(_bs_lane(89, 1, 256, 8, 21.0, 10.25, 20.0, 10.25))
		items.handle({
			"t": "bs", "k": 990, "p": 20, "w": 100, "fx": 0, "fy": 0, "fr": 16,
			"lm": lm_old,
			"sl": [81, 990, 1, 888, 1, 16, 1, 89, 990, 1, 902, 1, 64, 1],
			"dl": [81],
			"of": [10, 0],
		})
		items._process(1.0 / 60.0)
		# Advance simulation a few ticks to verify unit 10 stayed OFF while unit 11 moved:
		for f in 4:
			items.handle({"t": "bs", "k": 1001 + f, "p": 6, "w": 100, "fx": 5 * 256, "fy": 10 * 256, "fr": 48})
			items._process(1.0 / 60.0)

		var raw81: PackedInt32Array = items._state.lanes_raw.get(81, PackedInt32Array())
		var im: Dictionary = _sim_item_map(items._state.sim)
		var pos901: int = int((im[901] as Array)[1]) if im.has(901) else -1
		var pos902: int = int((im[902] as Array)[1]) if im.has(902) else -1
		check(items._state.period == 6 and items._state.square == Vector3(5.0, 10.0, 48.0),
			"belt_items (ndec=%s): stale k0=990 preserves square (%s) and period (%d)"
			% [str(ndec), str(items._state.square), items._state.period])
		check(items._state.lanes.has(81) and raw81.size() >= 4 and raw81[3] == 11 * 256
			and items._state.lanes.has(89) and int(items._state._lane_tick.get(89, -1)) == 990,
			"belt_items (ndec=%s): stale k0=990 skips lane 81 lm/dl (ex=%s) while applying unaffected lane 89"
			% [str(ndec), str(raw81[3] if raw81.size() >= 4 else -1)])
		check(im.has(901) and not im.has(888) and pos901 == 64 and im.has(902) and pos902 >= 0 and pos902 < 64,
			"belt_items (ndec=%s): stale k0=990 preserves item 901 & unit 10 off (pos=%d) while lane 89 moves (64->%d)"
			% [str(ndec), pos901, pos902])

		# 3. Newer dl at k=1010 prevents stale k0=1005 lm/sl from resurrecting deleted lane 81:
		items.handle({"t": "bs", "k": 1010, "p": 6, "w": 100, "fx": 5 * 256, "fy": 10 * 256, "fr": 48, "dl": [81]})
		items._process(1.0 / 60.0)
		items.handle({
			"t": "bs", "k": 1005, "p": 6, "w": 100, "fx": 5 * 256, "fy": 10 * 256, "fr": 48,
			"lm": _bs_lane(81, 1, 256, 8, 11.0, 10.25, 10.0, 10.25),
			"sl": [81, 1005, 1, 889, 1, 32, 1],
		})
		items._process(1.0 / 60.0)
		var im_after: Dictionary = _sim_item_map(items._state.sim)
		check(not items._state.lanes.has(81) and not im_after.has(889) and int(items._state._lane_tick.get(81, -1)) == 1010,
			"belt_items (ndec=%s): newer dl k=1010 prevents stale k0=1005 lm/sl resurrection" % str(ndec))

		items.reset()
		check(items._state._square_tick == -1 and items._state._lane_tick.is_empty() and items._state._off_tick.is_empty(),
			"belt_items (ndec=%s): reset() clears tick guards" % str(ndec))
		remove_child(items)
		items.queue_free()

	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.State.lattice_native = was_lat_nat
	BeltItemsScript.Job.native_decode = was_dec
	BeltItemsScript.Job.view_cull = was_cull


## The review's must-fixes: retransmits handled in order (reliable_reorder), and a chunk's delta never
## overtaking an older one waiting in bulk (prio_delta_order); each with its switch off as before.
func _test_reorder_and_delta_order() -> void:
	for reorder: bool in [true, false]:
		var b: Node = _make_bridge()
		b.reliable_reorder = reorder
		var got: Array = []
		var on_msg := func(m: Dictionary) -> void:
			got.append("%s%d" % [str(m.get("t", "")), int(m.get("r", 0))])
		b.message_received.connect(on_msg)
		b._expected_r = 5
		# The chunk header (5) lost; its ents (6, 7) arrive; then the retransmitted header.
		b._route([{"t": "ents", "r": 6, "k": 1, "cx": 2, "cy": 2, "part": 1, "parts": 2, "e": []},
			{"t": "ents", "r": 7, "k": 1, "cx": 2, "cy": 2, "part": 2, "parts": 2, "e": []}], PackedInt32Array(), 0)
		b._drain()
		b._route([{"t": "chunk", "r": 5, "k": 1, "cx": 2, "cy": 2}], PackedInt32Array(), 0)
		b._drain()
		if reorder:
			check(got == ["chunk5", "ents6", "ents7"] and b._expected_r == 8 and b._nack_pending.is_empty()
				and b._pending_resync == 0, "reorder: a retransmitted chunk header goes before its ents: %s" % [got])
		else:
			check(got == ["ents6", "ents7", "chunk5"], "--reliable-reorder=off: handled as they came, as before: %s" % [got])
		b.queue_free()

	# Two gaps, filled out of order; a duplicate of a held one dropped.
	var b2: Node = _make_bridge()
	var got2: Array = []
	var on2 := func(m: Dictionary) -> void:
		got2.append(int(m.get("r", 0)))
	b2.message_received.connect(on2)
	b2._expected_r = 1
	for r: int in [2, 4, 4, 3, 1]:
		b2._route([{"t": "inv", "r": r, "l": []}], PackedInt32Array(), 0)
	b2._drain()
	check(got2 == [1, 2, 3, 4] and b2._expected_r == 5 and b2._nack_pending.is_empty() and b2._reorder.is_empty()
		and int(b2.stats["nacks_sent"]) == 2, "reorder: two gaps filled out of order, duplicate dropped: %s nacks=%d" % [got2, int(b2.stats["nacks_sent"])])

	# The NACK times out: what was held is handed on in order, a resync asked for, the late one dropped.
	got2.clear()
	b2._route([{"t": "inv", "r": 7, "l": []}, {"t": "inv", "r": 8, "l": []}], PackedInt32Array(), 0)
	check(b2._reorder.size() == 2 and b2._nack_pending.has(5) and b2._nack_pending.has(6), "reorder: 7 and 8 held behind 5-6")
	b2._nack_pending[5] = Time.get_ticks_msec() - BridgeScript.NACK_TIMEOUT_MSEC - 50
	b2._pending_resync = 0
	b2._check_nack_timeouts()
	b2._drain()
	b2._route([{"t": "inv", "r": 6, "l": []}, {"t": "inv", "r": 9, "l": []}], PackedInt32Array(), 0)
	b2._drain()
	check(got2 == [7, 8, 9] and b2._pending_resync == 1 and b2._reorder.is_empty() and b2._reorder_gap_ok.is_empty()
		and b2._expected_r == 10 and int(b2.stats["nack_late_drops"]) == 1,
		"reorder: timeout hands on 7, 8 in order, resyncs, drops the late 6: %s resync=%d" % [got2, b2._pending_resync])

	# Full buffer or a gap too wide while holding: gives up the same way (bounded).
	got2.clear()
	b2._pending_resync = 0
	b2._route([{"t": "inv", "r": 12, "l": []}, {"t": "inv", "r": 12 + BridgeScript.NACK_MAX_GAP + 5, "l": []}], PackedInt32Array(), 0)
	b2._drain()
	check(got2 == [12, 12 + BridgeScript.NACK_MAX_GAP + 5] and b2._pending_resync == 1 and b2._reorder.is_empty()
		and b2._nack_pending.is_empty(), "reorder: a gap too wide while holding gives up in order: %s" % [got2])
	b2.queue_free()

	# Receive path (the tests' and fuzz's): the same gate.
	var b3: Node = _make_bridge()
	var got3: Array = []
	var on3 := func(m: Dictionary) -> void:
		got3.append(int(m.get("r", 0)))
	b3.message_received.connect(on3)
	b3._expected_r = 3
	for r: int in [4, 3]:
		b3.receive(JSON.stringify({"t": "inv", "r": r, "l": []}).to_utf8_buffer())
	check(got3 == [3, 4], "reorder via receive(): %s" % [got3])
	b3.queue_free()

	# prio_delta_order: add X waits in bulk behind its chunk's ents; the chunk's ents drain; del X
	# must not overtake add X through the priority lane.
	for order_on: bool in [true, false]:
		var b4: Node = _make_bridge()
		b4.prio_delta_order = order_on
		var got4: Array = []
		var on4 := func(m: Dictionary) -> void:
			got4.append(str(m.get("t", "")))
		b4.message_received.connect(on4)
		b4._route([{"t": "ents", "r": 1, "k": 1, "cx": 0, "cy": 0, "part": 1, "parts": 1, "e": []},
			{"t": "add", "r": 2, "k": 1, "e": [7, 1, 128, 128, 0]}], PackedInt32Array(), 0)
		# Only the ents are handled this frame (as when the frame's budget runs out).
		var ents_only: Dictionary = b4._waiting[0]
		b4._waiting_at = 1
		b4._routed_out(ents_only)
		b4.message_received.emit(ents_only)
		b4._route([{"t": "del", "r": 3, "k": 2, "x": 128, "y": 128}], PackedInt32Array(), 0)
		b4._drain()
		if order_on:
			check(got4 == ["ents", "add", "del"] and b4._chunk_waiting.is_empty(),
				"prio_delta_order: del waits behind the queued add of its chunk: %s cw=%s" % [got4, b4._chunk_waiting])
		else:
			check(got4 == ["ents", "del", "add"], "--prio-delta-order=off: del overtakes add, as before: %s" % [got4])
		b4.queue_free()


## A bridge as just after the welcome was handled: connected, `ready` not handled yet.
func _handshake_bridge(guard: bool) -> Node:
	var b: Node = _make_bridge()
	b.resync_guard = guard
	b.connected = false
	b.world_ready = false
	b._seq_connected = false
	b._seq_world_ready = false
	b._prio_barriers = 0
	b._expected_r = 1
	b._route([{"t": "welcome", "r": 1, "v": BridgeScript.PROTOCOL}], PackedInt32Array(), Time.get_ticks_usec())
	b._drain()
	return b


func _test_resync_guard() -> void:
	var now := Time.get_ticks_msec()
	# 1. The second PC's loop: the handshake's end read (`ready` among it) but the drain more than
	# HANDSHAKE_STALL_MSEC behind. The old check asked for a full resync; the guard doesn't.
	for guard: bool in [true, false]:
		var b: Node = _handshake_bridge(guard)
		var ok_start: bool = b.connected and not b.world_ready
		b._route([
			{"t": "protos", "r": 2, "part": 1, "parts": 1, "l": []},
			{"t": "ready", "r": 3},
			{"t": "zz", "k": 5},
		], PackedInt32Array(), Time.get_ticks_usec())
		b.last_reliable_msec = now - BridgeScript.HANDSHAKE_STALL_MSEC - 1000
		b._check_handshake_stall(now)
		if guard:
			check(ok_start and b._seq_world_ready and b._pending_resync == 0,
				"resync guard: no handshake-stall resync while `ready` waits in the queue (pending=%d)" % b._pending_resync)
			b._drain()
			check(b.world_ready and b._full_streak == 0, "resync guard: the queued `ready` is handled on the next drain")
		else:
			check(ok_start and b._pending_resync == 2,
				"--resync-guard=off: the old stall check asks for a full resync (pending=%d)" % b._pending_resync)
		b.queue_free()
	# The handshake's end really lost (`ready` never read): still a full resync.
	var lost: Node = _handshake_bridge(true)
	lost.last_reliable_msec = now - BridgeScript.HANDSHAKE_STALL_MSEC - 1000
	lost._check_handshake_stall(now)
	check(lost._pending_resync == 2, "resync guard: a lost `ready` still asks for a full resync (pending=%d)" % lost._pending_resync)
	lost.queue_free()

	# 2. Back-off: full resyncs without the world becoming ready wait 2.5, 5, 10, 20, 30 s.
	var b2: Node = _handshake_bridge(true)
	b2.capture = []
	b2._last_resync_msec = -1000000
	b2.request_resync(true)
	b2._send_resync()
	var c1: int = b2.full_resync_cooldown()
	b2.request_resync(true)
	b2._last_resync_msec = Time.get_ticks_msec() - BridgeScript.FULL_RESYNC_COOLDOWN_MSEC - 100
	b2._send_resync()
	var held_backoff: bool = int(b2.stats["full_resyncs"]) == 1 and b2._pending_resync == 2
	b2._last_resync_msec = Time.get_ticks_msec() - c1 - 100
	b2._send_resync()
	var cooldowns: Array = []
	for n in 7:
		b2._full_streak = n
		cooldowns.append(b2.full_resync_cooldown())
	b2._full_streak = 2
	check(c1 == 2 * BridgeScript.FULL_RESYNC_COOLDOWN_MSEC and held_backoff and int(b2.stats["full_resyncs"]) == 2
		and cooldowns == [2500, 5000, 10000, 20000, 30000, 30000, 30000],
		"resync guard: full resyncs back off (first wait %d, held %s, sent %d, waits %s)" % [c1, held_backoff, int(b2.stats["full_resyncs"]), cooldowns])
	# 3. Not asked again while the last one's welcome waits in the queue; the old session's messages
	# read before it are dropped, not handled.
	var got: Array = []
	var on_msg := func(m: Dictionary) -> void:
		got.append(str(m.get("t", "")))
	b2.message_received.connect(on_msg)
	b2._route([
		{"t": "chunk", "r": 2, "cx": 0, "cy": 0},
		{"t": "zz", "k": 9},
		{"t": "ents", "r": 3, "cx": 0, "cy": 0},
	], PackedInt32Array(), Time.get_ticks_usec())
	b2._route([{"t": "welcome", "r": 1, "v": BridgeScript.PROTOCOL}, {"t": "ready", "r": 2}], PackedInt32Array(), Time.get_ticks_usec())
	b2.request_resync(true)
	b2._last_resync_msec = -1000000
	b2._send_resync()
	var held_inflight: bool = int(b2.stats["full_resyncs"]) == 2 and b2._pending_resync == 2 and b2._full_welcome_read
	for i in 4:
		b2._drain()
	check(held_inflight and got == ["ready"] and b2.stale_dropped == 3 and b2._chunk_waiting.is_empty()
		and b2._prio_barriers == 0 and b2.world_ready and not b2._full_wait and b2._full_streak == 0 and b2._pending_resync == 0,
		"resync guard: held while its welcome waits (%s), old session dropped (got %s, dropped %d, chunk books %s, barriers %d), ready resets the back-off (streak %d)"
		% [held_inflight, got, b2.stale_dropped, b2._chunk_waiting, b2._prio_barriers, b2._full_streak])
	b2.queue_free()

	# 4. --resync-guard=off: the old session's messages are handled as before.
	var b3: Node = _make_bridge()
	b3.resync_guard = false
	var got3: Array = []
	var on_msg3 := func(m: Dictionary) -> void:
		got3.append(str(m.get("t", "")))
	b3.message_received.connect(on_msg3)
	b3._route([{"t": "zz", "k": 9}, {"t": "welcome", "r": 1, "v": BridgeScript.PROTOCOL}], PackedInt32Array(), Time.get_ticks_usec())
	for i in 3:
		b3._drain()
	check(got3 == ["zz"] and b3.stale_dropped == 0, "--resync-guard=off: messages before a welcome handled as before (%s)" % [got3])
	b3.queue_free()

	# 5. The hello says the welcome came (w 1) once it is read, not only once handled (guard on).
	var ws: Array = []
	for guard: bool in [true, false]:
		var b5: Node = _make_bridge()
		b5.resync_guard = guard
		b5.connected = false
		b5._seq_connected = false
		b5._route([{"t": "welcome", "r": 1, "v": BridgeScript.PROTOCOL}], PackedInt32Array(), Time.get_ticks_usec())
		b5.capture = []
		b5._send_hello()
		var hello: Dictionary = {}
		for m in _parsed_capture(b5):
			if str((m as Dictionary).get("t", "")) == "hello":
				hello = m
		ws.append(int(hello.get("w", -1)))
		b5.queue_free()
	check(ws == [1, 0], "hello w: 1 once the welcome is read with the guard, 0 until handled without it (%s)" % [ws])
	# After the client's own timeout the hello asks for the welcome again (w 0).
	var b6: Node = _make_bridge()
	b6._seq_connected = false
	b6._route([{"t": "welcome", "r": 1, "v": BridgeScript.PROTOCOL}], PackedInt32Array(), Time.get_ticks_usec())
	b6._drain()
	b6._last_packet_msec = Time.get_ticks_msec() - BridgeScript.TIMEOUT_MSEC - 1000
	b6._quiet_by.clear()
	b6._check_timeout()
	b6.capture = []
	b6._send_hello()
	var w6 := -1
	for m in _parsed_capture(b6):
		if str((m as Dictionary).get("t", "")) == "hello":
			w6 = int((m as Dictionary).get("w", -1))
	check(not b6.connected and w6 == 0, "hello w 0 again after the client's timeout (connected %s, w %d)" % [b6.connected, w6])
	b6.queue_free()
