extends "res://tests/ui_test_base.gd"
## UI test sections: belts.

func _belt_drop_show() -> void:
	const Arms := preload("res://scripts/world/inserter_arms.gd")
	var was_cull: bool = BeltItemsScript.Job.view_cull
	var was_gd: bool = BeltItemsScript.State.force_gd
	var was_dn: bool = BeltItemsScript.State.draw_native
	var was_show: bool = BeltItemsScript.drop_show_now
	var was_glide: bool = BeltItemsScript.drop_glide
	var was_ev: bool = Arms.events
	var was_ho: bool = Arms.handoff
	Arms.events = true
	Arms.handoff = true
	BeltItemsScript.Job.view_cull = false
	var twins: Array = [[true, false]]
	if ClassDB.class_exists("BeltSimNative"):
		twins.append([false, false])
		twins.append([false, true])
	var show_at_by_twin: Array = []
	for tw: Array in twins:
		var force_gd: bool = bool(tw[0])
		var draw_nat: bool = bool(tw[1])
		var what := "%s/%s" % ["belt_sim.gd" if force_gd else "BeltSimNative", "BeltDrawNative" if draw_nat else "GDScript"]
		BeltItemsScript.State.force_gd = force_gd
		BeltItemsScript.State.draw_native = draw_nat
		BeltItemsScript.drop_glide = true
		var items = BeltItemsScript.new()
		add_child(items)
		items._sync = true
		# One lane along +x, its exit at (2, 10), moving 8/256 a tick; nothing on it.
		_bs_feed(items, 1990, {"lm": _bs_lane(9, 1, 256, 8, 2.0, 10.0, 1.0, 10.0)})
		for k in range(1991, 2000):
			_bs_feed(items, k, {}, 1)
		items.predict_drop(3, 1.5, 10.1)
		items.predict_drop(3, 1.5, 14.0)  # (off the belts: nothing)
		_bs_feed(items, 2000, {}, 1)
		var shown: Array = items.drops_shown().duplicate(true)
		var at0: Vector3 = shown[0][1] if shown.size() == 1 else Vector3.INF
		var t_start: float = items._drawn
		check(shown.size() == 1 and absf(at0.x - 1.5) < 0.02 and absf(at0.z - 10.0) < 0.02 and int(shown[0][2]) == -1
			and t_start < 2001.0 and not items.has_item(777),
			"drop show (%s): Z over a belt shows the item at once on the lane under it (%s), ahead of the drawn clock (%.1f); none off the belts: %s" % [what, at0, t_start, shown])
		# Step two ticks before `ie` arrives: drop card glides forward along +x immediately.
		_bs_feed(items, 2001, {}, 1)
		_bs_feed(items, 2002, {}, 1)
		var mid_shown: Array = items.drops_shown()
		var mid_x: float = (mid_shown[0][1] as Vector3).x if mid_shown.size() == 1 else -INF
		check(mid_shown.size() == 1 and mid_x > at0.x + 0.01,
			"Other #1 (%s): drop card glides forward immediately before ie arrives (x %.4f -> %.4f)" % [what, at0.x, mid_x])
		# The bridge's put: on tick 2003, at the lane's middle (line position 128), the game's id 777.
		var put_tick := 2003
		var lag_ticks := maxf(0.0, float(put_tick) - t_start)
		var want_handoff := put_tick + mini(ceili(lag_ticks * BeltItemsScript.DROP_GLIDE_ALPHA / (1.0 - BeltItemsScript.DROP_GLIDE_ALPHA)), BeltItemsScript.DROP_MAX_CATCHUP)
		items.handle({"t": "ie", "k": put_tick, "n": 6, "p": 2, "part": 1, "parts": 1, "l": [6, 0, put_tick, 9, 128, 777, 3, 1, 1]})
		var both := false
		var gap := false
		var gone_at := -1.0
		var recorded_show := -1.0
		var last_drop_x := -INF
		var snap_err := INF
		for k in range(2003, 2024):
			var pre_shown: Array = items.drops_shown()
			if pre_shown.size() == 1:
				last_drop_x = (pre_shown[0][1] as Vector3).x
			_bs_feed(items, k, {}, 1)
			var sh_now: float = items.show_of(777)
			if sh_now >= 0.0 and recorded_show < 0.0:
				recorded_show = sh_now
			var still: bool = not items.drops_shown().is_empty()
			var real: bool = items.has_item(777) and items._drawn >= float(want_handoff)
			if not still and real and snap_err > 1.0e8 and last_drop_x > -1.0e8:
				var rpos: Variant = items.position_of(777)
				if rpos is Vector3:
					snap_err = absf((rpos as Vector3).x - (last_drop_x + 8.0 / 256.0))
			both = both or (still and real)
			gap = gap or (not still and not real)
			if not still and gone_at < 0.0:
				gone_at = items._drawn
		show_at_by_twin.append(recorded_show)
		check(not both and not gap and gone_at >= float(want_handoff) and is_equal_approx(recorded_show, float(want_handoff))
			and snap_err <= 0.04 and items.has_item(777) and items.drops_shown().is_empty(),
			"Other #1 (%s): glide hands off at put + capped catchup (show_of=%.1f want=%d gone=%.1f snap=%.4f both=%s gap=%s)" % [what, recorded_show, want_handoff, gone_at, snap_err, both, gap])
		# Never told (out of reach, the belt full there): it goes after DROP_SHOW_MSEC.
		items.predict_drop(3, 1.2, 10.1)
		_bs_feed(items, 2024, {}, 1)
		var n_before: int = items.drops_shown().size()
		for d: Array in items.drops_shown():
			d[3] = int(d[3]) - BeltItemsScript.DROP_SHOW_MSEC - 1
		items._process(1.0 / 60.0)
		check(n_before == 1 and items.drops_shown().is_empty(),
			"drop show (%s): one the bridge never confirms goes after %d ms (%d shown before)" % [what, BeltItemsScript.DROP_SHOW_MSEC, n_before])
		# --belt-drop-glide=off: legacy static drop card hands off at put (2003.0) with show_of == put.
		BeltItemsScript.drop_glide = false
		var off_items = BeltItemsScript.new()
		add_child(off_items)
		off_items._sync = true
		_bs_feed(off_items, 1990, {"lm": _bs_lane(9, 1, 256, 8, 2.0, 10.0, 1.0, 10.0)})
		for k in range(1991, 2000):
			_bs_feed(off_items, k, {}, 1)
		off_items.predict_drop(3, 1.5, 10.1)
		_bs_feed(off_items, 2000, {}, 1)
		var off_at0: Vector3 = off_items.drops_shown()[0][1] if off_items.drops_shown().size() == 1 else Vector3.INF
		_bs_feed(off_items, 2001, {}, 1)
		var off_at1: Vector3 = off_items.drops_shown()[0][1] if off_items.drops_shown().size() == 1 else Vector3.INF
		off_items.handle({"t": "ie", "k": 2003, "n": 6, "p": 2, "part": 1, "parts": 1, "l": [6, 0, 2003, 9, 128, 778, 3, 1, 1]})
		var off_both := false
		var off_gap := false
		var off_gone := -1.0
		var off_show := -1.0
		for k in range(2002, 2016):
			_bs_feed(off_items, k, {}, 1)
			var osh: float = off_items.show_of(778)
			if osh >= 0.0 and off_show < 0.0:
				off_show = osh
			var ostill: bool = not off_items.drops_shown().is_empty()
			var oreal: bool = off_items.has_item(778) and off_items._drawn >= 2003.0
			off_both = off_both or (ostill and oreal)
			off_gap = off_gap or (not ostill and not oreal)
			if not ostill and off_gone < 0.0:
				off_gone = off_items._drawn
		check(off_at0.is_equal_approx(off_at1) and not off_both and not off_gap and off_gone >= 2003.0
			and (off_show < 0.0 or is_equal_approx(off_show, 2003.0)) and off_items.has_item(778) and off_items.drops_shown().is_empty(),
			"Other #1 (%s): --belt-drop-glide=off keeps static drop card and hands off at put 2003 (show=%.1f gone=%.1f both=%s gap=%s)" % [what, off_show, off_gone, off_both, off_gap])
		off_items.queue_free()
		BeltItemsScript.drop_glide = true
		BeltItemsScript.drop_show_now = false
		items.predict_drop(3, 1.5, 10.1)
		_bs_feed(items, 2025, {}, 1)
		check(items.drops_shown().is_empty(), "drop show (%s): --belt-drop-show-now=off shows nothing ahead, as before" % what)
		BeltItemsScript.drop_show_now = was_show
		# Bug batch 4 #4 (Z-drop desync regressions):
		# (a) High-lag cap: lag=36 caps handoff <= put_tick + DROP_MAX_CATCHUP.
		items.predict_drop(3, 1.5, 10.1)
		_bs_feed(items, 2026, {}, 1)
		for k in range(2027, 2061):
			_bs_feed(items, k, {}, 1)
		items.handle({"t": "ie", "k": 2061, "n": 6, "p": 2, "part": 1, "parts": 1, "l": [6, 0, 2061, 9, 128, 779, 3, 1, 1]})
		var lag_show := -1.0
		for k in range(2061, 2068):
			_bs_feed(items, k, {}, 1)
			if items.show_of(779) >= 0.0 and lag_show < 0.0:
				lag_show = items.show_of(779)
		check(lag_show >= 2061.0 and lag_show <= float(2061 + BeltItemsScript.DROP_MAX_CATCHUP),
			"Z-drop (%s): high-lag catchup is capped at +%d ticks (show_of=%.1f)" % [what, BeltItemsScript.DROP_MAX_CATCHUP, lag_show])
		for k in range(2068, 2080):
			_bs_feed(items, k, {}, 1)
		# (b) Pickup cancel: picked up (EV_PICKED) before handoff clears drop card immediately.
		items.predict_drop(3, 1.5, 10.1)
		_bs_feed(items, 2080, {}, 1)
		items.handle({"t": "ie", "k": 2086, "n": 6, "p": 2, "part": 1, "parts": 1, "l": [6, 0, 2086, 9, 128, 780, 3, 1, 1]})
		items.handle({"t": "ie", "k": 2087, "n": 6, "p": 2, "part": 1, "parts": 1, "l": [1, 50, 2087, 1, 3, 0, roundi(1.53125 * 256.0), roundi(10.0 * 256.0), 1]})
		for k in range(2081, 2096):
			_bs_feed(items, k, {}, 1)
		check(items.drops_shown().is_empty() and not items.has_item(780) and items._drawn < 2091.0,
			"Z-drop (%s): item gone/picked up before handoff clears drop card cleanly (%d left, drawn=%.1f)" % [what, items.drops_shown().size(), items._drawn])
		for k in range(2096, 2100):
			_bs_feed(items, k, {}, 1)
		# (c) Stop cancel: item hitting dead end / v==0 before handoff clears drop card & shows real item immediately.
		items.predict_drop(3, 1.9, 10.1)
		_bs_feed(items, 2100, {}, 1)
		items.handle({"t": "ie", "k": 2101, "n": 6, "p": 2, "part": 1, "parts": 1, "l": [6, 0, 2101, 9, 4, 781, 3, 1, 1]})
		for k in range(2101, 2109):
			_bs_feed(items, k, {}, 1)
		check(items.drops_shown().is_empty() and items.has_item(781) and items.show_of(781) < 0.0,
			"Z-drop (%s): dead-end/stopped item clears extra glide delay and shows immediately (shown=%d has=%s show_of=%.1f)" % [what, items.drops_shown().size(), items.has_item(781), items.show_of(781)])
		# (d) Already-loaded sl before ie (HAND_HAD): item already in sim clears drop card cleanly without double items.
		_bs_feed(items, 2110, {"sl": [9, 2110, 0]}, 1)
		items.predict_drop(3, 1.5, 10.1)
		_bs_feed(items, 2112, {}, 1)
		_bs_feed(items, 2113, {"sl": [9, 2113, 1, 782, 3, 128, 1]}, 1)
		items.handle({"t": "ie", "k": 2116, "n": 6, "p": 2, "part": 1, "parts": 1, "l": [6, 0, 2116, 9, 128, 782, 3, 1, 1]})
		for k in range(2114, 2124):
			_bs_feed(items, k, {}, 1)
		check(items.drops_shown().is_empty() and items.has_item(782),
			"Z-drop (%s): already-loaded sl item before ie clears drop card via HAND_HAD (shown=%d has=%s)" % [what, items.drops_shown().size(), items.has_item(782)])
		items.queue_free()
	# Verify GDScript and BeltDrawNative agree on show_of(uid).
	if show_at_by_twin.size() >= 2:
		check(is_equal_approx(float(show_at_by_twin[0]), float(show_at_by_twin[-1])),
			"Other #1: GDScript and BeltDrawNative show_of(uid) agree (%s)" % [show_at_by_twin])
	# Verify predict_drop does NOT pull job.fold_tick backwards and stalls/desyncs belts,
	# while draining _job.drops immediately on completion when fold_tick waits.
	BeltItemsScript.State.force_gd = true
	BeltItemsScript.State.draw_native = false
	BeltItemsScript.drop_show_now = true
	var zp_items = BeltItemsScript.new()
	add_child(zp_items)
	zp_items._sync = true
	_bs_feed(zp_items, 2100, {"lm": _bs_lane(9, 1, 256, 8, 2.0, 10.0, 1.0, 10.0)})
	zp_items._job_ticks = 8.0
	zp_items._sync = false
	zp_items.predict_drop(3, 1.5, 10.1)
	var zp_drawn_before: float = zp_items._drawn
	zp_items._start(0.016)
	var zp_job = zp_items._job
	check(zp_job != null and float(zp_job.fold_tick) >= zp_drawn_before + 8.0 - 0.001,
		"Z-drop: predict_drop keeps normal fold_tick advance without pulling belts backwards (fold=%.2f drawn=%.2f)" % [
			zp_job.fold_tick if zp_job != null else -1.0, zp_drawn_before])
	zp_items._wait()
	zp_items.queue_free()
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.State.draw_native = was_dn
	BeltItemsScript.drop_glide = was_glide
	BeltItemsScript.Job.view_cull = was_cull
	Arms.events = was_ev
	Arms.handoff = was_ho


## K9 (owner: "when an item is picked up off a belt the items behind it jump to the start of the belt instead
## of smoothly moving forward"): an inserter takes the only item on a belt's lane and the bridge reads that
## lane, empty, on the same tick, the update (`bs`) coming before the event (`ie`), as the bridge sends them.
## Drawn: the taken item leaves the belt and doesn't come back, and the item behind it goes on along the line,
## never drawn back towards the start of the belt; belt_sim.gd and its C++ twin alike. With
## --belt-sim-take-first=off (and --belt-sim-take-line=off, which also puts a tick's takes before its reads, and
## --belt-sim-rescue-seen=off, which lets the read's taken item go) the jump comes back (the old order: the read pushed both back).


func _belt_take() -> void:
	BeltItemsScript.Job.view_cull = false
	var was_gd: bool = BeltItemsScript.State.force_gd
	var sims := [true]
	if ClassDB.class_exists("BeltSimNative"):
		sims.append(false)
	for take_first in [true, false]:
		for force_gd in sims:
			BeltItemsScript.State.force_gd = force_gd
			BeltItemsScript.Job.take_first = take_first
			# (The old order is both switches off: --belt-sim-take-line puts a tick's takes before its reads
			# whatever came first.)
			BeltItemsScript.Job.take_line = take_first
			# (And --belt-sim-rescue-seen, which lets the read's taken item go: the old way pushed it back.)
			BeltItemsScript.Job.rescue_seen = take_first
			var items = BeltItemsScript.new()
			add_child(items)
			items._sync = true
			# Three yellow belts along +x at y 10 (belt u from x = u to u + 1), an item on each.
			var lm: Array = []
			for u in [1, 2, 3]:
				lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, u + 1.0, 10.0, u, 10.0))
			_bs_feed(items, 1000, {"lm": lm, "sl": [25, 1000, 1, 30, 1, 200, 1, 17, 1000, 1, 20, 1, 128, 1, 9, 1000, 1, 10, 1, 100, 1]})
			var back := 0.0
			var last_x := -INF
			var taken_drawn := 0
			var seen := 0
			for k in range(1001, 1080):
				_bs_feed(items, k, {"sl": [17, 1010, 0]} if k == 1010 else {}, 0)
				if k == 1010:
					# (Belt 2's item is 48 into its lane then: the hand at x 3 - 48 / 256.)
					items.handle({"t": "ie", "k": 1010, "n": 6, "p": 2, "part": 1, "parts": 1, "l": [1, 99, 1010, 1, 1, 0, 720, 2560, 2]})
				items._process(1.0 / 60.0)
				var d = items.position_of(10)
				if d != null and items._drawn >= 1000.0:
					seen += 1
					back = maxf(back, last_x - (d as Vector3).x)
					last_x = (d as Vector3).x
				if items._drawn > 1013.0 and items.position_of(20) != null:
					taken_drawn += 1
			var what := "%s, take first %s" % ["belt_sim.gd" if force_gd else "BeltSimNative", "on" if take_first else "off"]
			if take_first:
				check(seen > 40 and back < 0.01 and taken_drawn == 0 and not items.has_item(20),
					"K9 (%s): a take off a belt read on its tick: the taken item isn't drawn after it (%d frames), the item behind never goes back (at most %.3f tiles, %d frames)" % [what, taken_drawn, back, seen])
			else:
				check(back > 0.1 or taken_drawn > 0, "K9 (%s): as before, the read first pushes them back (%.3f tiles, the taken item drawn %d frames after)" % [what, back, taken_drawn])
			items.queue_free()
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.Job.take_first = true
	BeltItemsScript.Job.take_line = true
	BeltItemsScript.Job.rescue_seen = true
	BeltItemsScript.Job.view_cull = true


## E46 (batches of items jumping about one update's travel on long straight runs): a moving item's record runs on
## to its line's end, so a stop between jobs (it catches up with the item standing in front) was drawn past and
## pulled back at the next job. A dead-end lane of four belts going -x to x 0, item 10 standing at its end,
## item 11 coming up behind it and stopping a gap behind it (x 0.25) at tick 1067; the last job before the drawn
## clock gets there knows the stop. With early stop (--belt-draw-early-stop) that job's record of item 11 ends at the stop:
## drawn at tick 1080 (no job since) it stands there. Off, as before: drawn on to the line's end, a gap past
## it. belt_sim.gd with its records, BeltSimNative with the GDScript records and with BeltDrawNative.


func _belt_early_stop() -> void:
	BeltItemsScript.Job.view_cull = false
	var was_gd: bool = BeltItemsScript.State.force_gd
	var was_dn: bool = BeltItemsScript.State.draw_native
	var twins := [[true, false]]
	if ClassDB.class_exists("BeltSimNative"):
		twins.append([false, false])
		twins.append([false, true])
	for early_stop in [true, false]:
		for tw: Array in twins:
			BeltItemsScript.State.force_gd = tw[0]
			BeltItemsScript.State.draw_native = tw[1]
			BeltItemsScript.Job.early_stop = early_stop
			var items = BeltItemsScript.new()
			add_child(items)
			items._sync = true
			var ox := 0.0
			var oy := 10.0
			var lm: Array = _bs_lane(9, 1, 1024, 8, ox, oy, ox + 4.0, oy)
			_bs_feed(items, 1000, {"lm": lm, "sl": [9, 1000, 2, 10, 1, 0, 1, 11, 1, 600, 1]})
			var at_stop = null
			var stop_known := false
			for k in range(1001, 1075):
				_bs_feed(items, k, {}, 1)
				items.position_of(10)
				items.position_of(11)
				if items._drawn < 1066.5:
					# (The last job before the drawn clock gets to the stop, the simulation stepped past it (it stops
					# at 1067, the bridge's updates up to 1072 in): drawn later, no job since.)
					stop_known = k >= 1071
					var drawn: float = items._drawn
					items._drawn = 1080.0
					at_stop = items.position_of(11)
					items._drawn = drawn
			var what := "%s, %s records, early stop %s" % ["belt_sim.gd" if tw[0] else "BeltSimNative",
				"BeltDrawNative" if items._state.draw != null else "GDScript", "on" if early_stop else "off"]
			var x := -1.0 if at_stop == null else (at_stop as Vector3).x
			if early_stop:
				check(stop_known and absf(x - (ox + 0.25)) < 0.02,
					"E46 (%s): the record of an item running into a stop between jobs ends at the stop (x %.3f, want %.3f)" % [what, x, ox + 0.25])
			else:
				check(stop_known and x >= 0.0 and x < ox + 0.1, "E46 (%s): as before, drawn on past the stop to the line's end (x %.3f)" % [what, x])
			items.queue_free()
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.State.draw_native = was_dn
	BeltItemsScript.Job.early_stop = true
	BeltItemsScript.Job.view_cull = true


## The debug menu's Simulation tab (owner: "start belt fixes on and can be turned off in a new debug menu for
## simulation options"): a box per belt fix (belt_items.gd LIVE), each starting as the command line set it; a
## public build changes none; a box changes nothing a running job reads, only the next job's start takes it,
## into the statics and the simulation's own switches (belt_sim.gd and BeltSimNative alike); and early stop
## switched off from the menu mid-run draws the item past the stop as --belt-draw-early-stop=off does (E46's
## scene, GDScript and BeltDrawNative records).


func _belt_line_end() -> void:
	BeltItemsScript.Job.view_cull = false
	var was_gd: bool = BeltItemsScript.State.force_gd
	var sims := [true]
	if ClassDB.class_exists("BeltSimNative"):
		sims.append(false)
	for mode in ["fixed", "take line off", "settle off"]:
		for force_gd in sims:
			BeltItemsScript.State.force_gd = force_gd
			BeltItemsScript.Job.take_line = mode != "take line off"
			# (The old way is take_edge off too: a take now finds its item past the belt's front edge.)
			BeltItemsScript.Job.take_edge = mode != "take line off"
			BeltLatticeScript.settle = mode != "settle off"
			var items = BeltItemsScript.new()
			add_child(items)
			items._sync = true
			# (In the client's planned ground: the lattice draws only lanes there.)
			var uvr: Rect2 = items._view_rect()
			var ox := floorf(uvr.get_center().x) - 3.0 if uvr.size.x > 0.0 else 0.0
			var oy := floorf(uvr.get_center().y) + 0.5 if uvr.size.x > 0.0 else 30.0
			# Belt u from x = ox + u to ox + u + 1, items going towards -x: the line ends at x = ox + 1.
			var lm: Array = []
			var sl: Array = []
			var game := {}  # uid -> place along the line (1/256, 0 its end)
			for u in range(1, 7):
				lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, ox + u, oy, ox + u + 1.0, oy))
				sl.append_array([u * 8 + 1, 3000, 4])
				for q in 4:
					var uid := 100 + 4 * (u - 1) + q
					game[uid] = (u - 1) * 256 + 64 * q
					sl.append_array([uid, 1, 64 * q, 1])
			_bs_feed(items, 3000, {"lm": lm, "sl": sl}, 1)
			var k := 3000
			for f in 30:
				k += 1
				_bs_feed(items, k, {}, 1)
				for uid: int in game:
					items.position_of(uid)
			# The hand takes item 108 (belt 3's front) before tick `at`; from `at` on the items behind close up.
			var at := k + 4
			var taken := 108
			var taken_place: int = game[taken]
			game.erase(taken)
			var lat_native: bool = not (items._state.lattice is BeltLatticeScript)
			var last := {}
			var back := 0.0
			var taken_drawn := 0
			var lat_moving := 0
			var lat_frames := 0
			var close_mid := 0.0
			var close_end := 0.0
			for t in range(k + 1, at + 70):
				if t > at:
					var order: Array = game.keys()
					order.sort_custom(func(a: int, b: int) -> bool: return int(game[a]) < int(game[b]))
					var prev := -64
					for u2: int in order:
						game[u2] = mini(int(game[u2]), maxi(int(game[u2]) - 8, prev + 64))
						prev = int(game[u2])
				var extra := {}
				if t == at + 1:
					# (A tick into the closing: the lane behind first, then the pickup lane, as the game has them.)
					var reads: Array = []
					for u in [4, 3]:
						var its: Array = []
						var order2: Array = game.keys()
						order2.sort_custom(func(a: int, b: int) -> bool: return int(game[a]) < int(game[b]))
						for u2: int in order2:
							var g := int(game[u2])
							if g >= (u - 1) * 256 and g < u * 256:
								its.append_array([u2, 1, g - (u - 1) * 256, 1])
						reads.append_array([u * 8 + 1, t, its.size() / 4])
						reads.append_array(its)
					extra["sl"] = reads
				_bs_feed(items, t, extra, 0)
				if t == at + 1:
					items.handle({"t": "ie", "k": t, "n": 6, "p": 2, "part": 1, "parts": 1,
						"l": [1, 99, t, 1, 1, 0, roundi((ox + 1.0) * 256.0) + taken_place, roundi(oy * 256.0), 3]})
				items._process(1.0 / 60.0)
				if items._drawn < float(k):
					continue
				for uid: int in game:
					var d = items.position_of(uid)
					if d != null:
						if last.has(uid):
							back = maxf(back, (d as Vector3).x - float(last[uid]))
						last[uid] = (d as Vector3).x
				if items._drawn > float(at + 4) and items.position_of(taken) != null:
					taken_drawn += 1
				# (close) How far the lattice draws belts 5 and 6's slots off their standing places (every 0.25 tile).
				var lat_kks: Array = items._state.lattice.kinds.keys() if not lat_native else items._state.lattice.kind_keys()
				var off_grid := 0.0
				for kk in lat_kks:
					for e in items.drawn_lattice(kk):
						if e == null:
							continue
						var lx: float = (e[0] as Vector3).x - ox
						if lx >= 5.0 and lx < 7.0 and absf((e[0] as Vector3).z - oy) < 0.3:
							off_grid = maxf(off_grid, absf(lx * 4.0 - roundf(lx * 4.0)) / 4.0)
				if items._drawn > float(at) and items._drawn < float(at + 9):
					close_mid = maxf(close_mid, off_grid)
				close_end = off_grid
				for u in [5, 6]:
					var lv := -1
					if lat_native:
						lv = items._state.lattice.drawn_speed(u * 8 + 1)
					else:
						var ln = items._state.lattice.drawn.get(u * 8 + 1)
						if ln != null:
							lv = ln.v
					if lv >= 0:
						lat_frames += 1
						if lv > 0:
							lat_moving += 1
			var xs: Array = last.values()
			xs.sort()
			var close := 0
			for i in range(1, xs.size()):
				if float(xs[i]) - float(xs[i - 1]) < 0.24:
					close += 1
			var what := "%s, %s" % ["belt_sim.gd" if force_gd else "BeltSimNative", mode]
			if mode == "fixed":
				check(not items.has_item(taken) and taken_drawn == 0 and xs.size() == 23 and back < 0.01 and close == 0,
					"K19 (%s): a take off a line that ends, the reads of its tick first: the taken item is gone (drawn %d frames after), 23 items drawn (%d), none goes back (%.3f tile), none closer than a gap (%d)"
					% [what, taken_drawn, xs.size(), back, close])
				check(lat_frames > 0 and lat_moving == 0,
					"K19 (%s): the lattice of the lanes behind stands while the line closes one gap (%d of %d lane-frames moving)" % [what, lat_moving, lat_frames])
				check(close_mid > 0.05 and close_end < 0.01,
					"K19 (%s, --belt-draw-lattice-close): the lattice of the lanes behind slides a gap with the closing, as a group, and stands on its places again (the most off its places mid-way %.3f tile, at the end %.3f)" % [what, close_mid, close_end])
			elif mode == "take line off":
				check(items.has_item(taken), "K19 (%s): as before, the taken item stays on the belt" % what)
			else:
				check(lat_moving > 0, "K19 (%s): as before, the lanes behind take the belt's speed for the closing (%d of %d lane-frames)" % [what, lat_moving, lat_frames])
			items.queue_free()
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.Job.take_line = true
	BeltItemsScript.Job.take_edge = true
	BeltLatticeScript.settle = true
	BeltItemsScript.Job.view_cull = true


## E46 (owner: "items on belts sometimes hold in place for like 10 seconds or groups of items"): an inserter no `ie`
## tells of (past the bridge's hands radius) takes the front item of a backed-up line every 24 ticks, seen only in
## the bridge's read of the pickup belt; the lanes behind close a gap after each take. With
## --belt-draw-lattice-creep=step the lattice of those lanes slides a gap per take and stays a standing lane (speed 0:
## the mask a standing lane's); off (as before) it stands throughout (the freeze). Both simulations and both lattices.


func _belt_step_creep() -> void:
	BeltItemsScript.Job.view_cull = false
	var was_gd: bool = BeltItemsScript.State.force_gd
	var kept_native: bool = BeltItemsScript.State.lattice_native
	# [force_gd, lattice_native]: each simulation with the GDScript lattice, and the C++ lattice (on the C++ simulation).
	var twins := [[true, false]]
	if ClassDB.class_exists("BeltSimNative"):
		twins.append([false, false])
		if ClassDB.class_exists("BeltLatticeNative"):
			twins.append([false, true])
	for mode in ["step", "off"]:
		for tw: Array in twins:
			var force_gd: bool = tw[0]
			BeltItemsScript.State.force_gd = force_gd
			BeltItemsScript.State.lattice_native = tw[1]
			BeltLatticeScript.creep = false
			BeltLatticeScript.creep_step = mode == "step"
			var items = BeltItemsScript.new()
			add_child(items)
			items._sync = true
			var uvr: Rect2 = items._view_rect()
			var ox := floorf(uvr.get_center().x) - 3.0 if uvr.size.x > 0.0 else 0.0
			var oy := floorf(uvr.get_center().y) + 0.5 if uvr.size.x > 0.0 else 30.0
			# Belt u from x = ox + u to ox + u + 1, items going towards -x: the line ends at x = ox + 1.
			var lm: Array = []
			var sl: Array = []
			var game := {}  # uid -> place along the line (1/256, 0 its end)
			for u in range(1, 7):
				lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, ox + u, oy, ox + u + 1.0, oy))
				sl.append_array([u * 8 + 1, 3000, 4])
				for q in 4:
					var uid := 100 + 4 * (u - 1) + q
					game[uid] = (u - 1) * 256 + 64 * q
					sl.append_array([uid, 1, 64 * q, 1])
			_bs_feed(items, 3000, {"lm": lm, "sl": sl}, 1)
			var k := 3000
			for f in 30:
				k += 1
				_bs_feed(items, k, {}, 1)
			var lat_native: bool = not (items._state.lattice is BeltLatticeScript)
			check(lat_native == bool(tw[1]), "E46: the lattice asked for is the one drawing (C++ %s)" % str(lat_native))
			var takes := 4
			var first := k + 4
			var lat_frames := 0
			var lat_moving := 0
			var slides := 0
			var run := 0
			var last_phase := -1.0
			var most_step := 0.0
			for t in range(k + 1, first + takes * 24 + 70):
				var tk := t - first
				if tk >= 0 and tk % 24 == 0 and tk / 24 < takes:
					var front := -1
					for uid: int in game:
						if int(game[uid]) == 0:
							front = uid
					game.erase(front)
				var order: Array = game.keys()
				order.sort_custom(func(a: int, b: int) -> bool: return int(game[a]) < int(game[b]))
				var prev := -64
				for u2: int in order:
					game[u2] = mini(int(game[u2]), maxi(int(game[u2]) - 8, prev + 64))
					prev = int(game[u2])
				var extra := {}
				if tk >= 0 and tk % 24 == 1 and tk / 24 < takes:
					# (The bridge's read of the pickup belt after the take: its front gone, the rest closing up.)
					var its: Array = []
					for u2: int in order:
						var g := int(game[u2])
						if g < 256:
							its.append_array([u2, 1, g, 1])
					extra["sl"] = [9, t, its.size() / 4] + its
				_bs_feed(items, t, extra, 0)
				items._process(1.0 / 60.0)
				if items._drawn < float(first):
					continue
				# Belt 5's lattice: its slots' phase along the line (every 0.25 tile) and how far it moved this frame.
				var lat_kks: Array = items._state.lattice.kinds.keys() if not lat_native else items._state.lattice.kind_keys()
				var phase := -1.0
				for kk in lat_kks:
					for e in items.drawn_lattice(kk):
						if e == null:
							continue
						var lx: float = (e[0] as Vector3).x - ox
						if lx >= 5.0 and lx < 6.0 and absf((e[0] as Vector3).z - oy) < 0.3:
							phase = fposmod(lx, 0.25)
				if phase >= 0.0 and last_phase >= 0.0:
					var dp := absf(fposmod(phase - last_phase + 0.125, 0.25) - 0.125)
					most_step = maxf(most_step, dp)
					# (A slide: frames in a row moving about the belt's speed a tick, 8/256 tile; a hop is one frame.)
					if dp > 0.01 and dp < 0.06:
						run += 1
						if run == 3:
							slides += 1
					else:
						run = 0
				last_phase = phase
				for u in [5, 6]:
					var lv := -1
					if lat_native:
						lv = items._state.lattice.drawn_speed(u * 8 + 1)
					else:
						var ln = items._state.lattice.drawn.get(u * 8 + 1)
						if ln != null:
							lv = ln.v
							if ln.mark_moving:
								lv = maxi(lv, 1)
					if lv >= 0:
						lat_frames += 1
						if lv > 0:
							lat_moving += 1
			var what := "%s, %s lattice" % ["belt_sim.gd" if force_gd else "BeltSimNative", "C++" if lat_native else "GDScript"]
			if mode == "step":
				check(slides >= takes - 1 and slides <= takes and lat_frames > 0 and lat_moving == 0,
					"E46 (%s, --belt-draw-lattice-creep=step): the lattice of a stop-and-go line slides a gap per take seen only in reads (%d slides for %d takes, at most %.3f tile a frame) and stays a standing lane (%d of %d lane-frames moving)"
					% [what, slides, takes, most_step, lat_moving, lat_frames])
			else:
				check(slides == 0 and lat_frames > 0,
					"E46 (%s): as before, the lattice of a stop-and-go line stands through its closings (%d slides, %d lane-frames)" % [what, slides, lat_frames])
			items.queue_free()
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.State.lattice_native = kept_native
	BeltLatticeScript.creep_step = false
	BeltItemsScript.Job.view_cull = true


## The stuck gap (owner: "after pulling items off a full backed up belt these gaps appear and items move past but
## the gap remains in the spot until it stops again"): a lattice lane going east (or south) marked the mask's cell
## past its exit, the lane ahead's first, so where that lane was drawn from the simulation (a take's lane given up)
## its items vanished in that cell as they went through it. --belt-draw-lattice-mask=own (the default): a lane marks
## its own cells only, its exit's cell past it unmarked; =entry, as before, marks it. Both lattices.


func _belt_lattice_mask_join() -> void:
	BeltItemsScript.Job.view_cull = false
	var was_gd: bool = BeltItemsScript.State.force_gd
	var kept_native: bool = BeltItemsScript.State.lattice_native
	var twins := [[true, false]]
	if ClassDB.class_exists("BeltSimNative") and ClassDB.class_exists("BeltLatticeNative"):
		twins.append([false, true])
	for mode in ["own", "entry"]:
		for tw: Array in twins:
			BeltItemsScript.State.force_gd = tw[0]
			BeltItemsScript.State.lattice_native = tw[1]
			BeltLatticeScript.mask_own = mode == "own"
			var items = BeltItemsScript.new()
			add_child(items)
			items._sync = true
			var uvr: Rect2 = items._view_rect()
			var ox := floorf(uvr.get_center().x) - 3.0 if uvr.size.x > 0.0 else 0.0
			var oy := floorf(uvr.get_center().y) + 0.5 if uvr.size.x > 0.0 else 30.0
			# Belt u from x = ox + u to ox + u + 1, items going east (+x), full and standing; belt 4 past them empty.
			var lm: Array = []
			var sl: Array = []
			for u in range(1, 5):
				lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, ox + u + 1.0, oy, ox + u, oy))
				sl.append_array([u * 8 + 1, 3000, 0 if u == 4 else 4])
				if u < 4:
					for q in 4:
						sl.append_array([100 + 4 * (u - 1) + q, 1, 64 * q, 1])
			_bs_feed(items, 3000, {"lm": lm, "sl": sl}, 1)
			for f in 30:
				_bs_feed(items, 3001 + f, {}, 1)
			var lat_native: bool = not (items._state.lattice is BeltLatticeScript)
			var what := "%s, %s lattice" % [mode, "C++" if lat_native else "GDScript"]
			if not items.lat_mask_has():
				check(false, "the stuck gap (%s): the lattice's mask is made" % what)
				items.queue_free()
				continue
			var cz := posmod(floori(oy * 4.0), 2048)
			var cell := func(x: float) -> bool: return items.lat_mask_pixel(posmod(floori(x * 4.0), 2048), cz)
			# (Belt 3's own exit cell, x ox + 3.75; belt 4's first, past belt 3's exit at x ox + 4: the join.)
			var own_ok: bool = cell.call(ox + 3.8) and cell.call(ox + 1.1)
			var past: bool = cell.call(ox + 4.1)
			if mode == "own":
				check(own_ok and not past and lat_native == bool(tw[1]),
					"the stuck gap (%s): a lattice lane going east marks its own cells, not the next belt's first (%s, %s)" % [what, own_ok, past])
			else:
				check(own_ok and past, "the stuck gap (%s, --belt-draw-lattice-mask=entry): as before, the next belt's first cell marked (%s, %s)" % [what, own_ok, past])
			items.queue_free()
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.State.lattice_native = kept_native
	BeltLatticeScript.mask_own = true
	BeltItemsScript.Job.view_cull = true


## Performance upgrades (A5 dedicated worker thread, A6b tiled f3d_belt_mask, A7 native bs body decode):
## verifies partial mask-tile uploads (with C++/GDScript parity), C++ apply_bs_body decode parity against GDScript,
## and async completion + clean teardown under both dedicated worker thread and WorkerThreadPool modes.


func _belt_perf_upgrades() -> void:
	var was_cull: bool = BeltItemsScript.Job.view_cull
	var was_gd: bool = BeltItemsScript.State.force_gd
	var was_lat_nat: bool = BeltItemsScript.State.lattice_native
	var was_tiled: bool = BeltLatticeScript.mask_tiled
	var was_dec: bool = BeltItemsScript.Job.native_decode
	var was_thr: bool = BeltItemsScript.job_thread
	BeltItemsScript.Job.view_cull = false

	# 1. Tiled lattice mask partial uploads + C++/GDScript parity.
	var twins := [[true, false]]
	if ClassDB.class_exists("BeltSimNative") and ClassDB.class_exists("BeltLatticeNative"):
		twins.append([false, true])
	var tile_pixels := {}
	for tw: Array in twins:
		var twin_name := "C++" if bool(tw[1]) else "GDScript"
		for tiled in [true, false]:
			BeltItemsScript.State.force_gd = bool(tw[0])
			BeltItemsScript.State.lattice_native = bool(tw[1])
			BeltLatticeScript.mask_tiled = bool(tiled)
			var items = BeltItemsScript.new()
			add_child(items)
			items._sync = true
			var oy := 10.5
			var cz := posmod(floori(oy * 4.0), 2048)
			var lm1: Array = []
			var sl1: Array = []
			for u in range(1, 4):
				lm1.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, 10.0 + u + 1.0, oy, 10.0 + u, oy))
				sl1.append_array([u * 8 + 1, 3000, 4])
				for q in 4:
					sl1.append_array([100 + 4 * u + q, 1, 64 * q, 1])
			_bs_feed(items, 3000, {"lm": lm1, "sl": sl1}, 1)
			for f in 12:
				_bs_feed(items, 3001 + f, {}, 1)
			var up0: int = int(items.stats.get("mask_tiles", 0))
			var has0: bool = items.lat_mask_has()
			var p1_cx := posmod(floori(12.5 * 4.0), 2048)
			var p1_ok: bool = items.lat_mask_pixel(p1_cx, cz)
			check(has0 and up0 == 16 and p1_ok,
				"mask tiles (%s, tiled=%s): initial upload sends all 16 tiles (%d) and marks lane (%s)" % [twin_name, str(tiled), up0, str(p1_ok)])
			# Second packed belt run inside tile (1, 0): cx in [640..660], away from tile 0.
			var lm2: Array = []
			var sl2: Array = []
			for u in range(11, 14):
				lm2.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, 150.0 + u + 1.0, oy, 150.0 + u, oy))
				sl2.append_array([u * 8 + 1, 3013, 4])
				for q in 4:
					sl2.append_array([200 + 4 * u + q, 1, 64 * q, 1])
			_bs_feed(items, 3013, {"lm": lm2, "sl": sl2}, 1)
			for f in 12:
				_bs_feed(items, 3014 + f, {}, 1)
			var up1: int = int(items.stats.get("mask_tiles", 0)) - up0
			var p2_cx := posmod(floori(162.5 * 4.0), 2048)
			var both_ok: bool = items.lat_mask_pixel(p1_cx, cz) and items.lat_mask_pixel(p2_cx, cz)
			if tiled:
				check(up1 == 1 and both_ok,
					"mask tiles (%s, tiled): second quadrant uploads 1 tile (%d), both marked (%s)" % [twin_name, up1, str(both_ok)])
				if not tile_pixels.has("first"):
					tile_pixels["first"] = [p1_ok, both_ok]
				else:
					var ref: Array = tile_pixels["first"]
					check(bool(ref[0]) == p1_ok and bool(ref[1]) == both_ok,
						"mask tiles (%s): C++ and GDScript tiled pixels match (%s == %s)" % [twin_name, str([p1_ok, both_ok]), str(ref)])
			else:
				check(up1 == 16 and both_ok,
					"mask tiles (%s, untiled): incremental upload sends all 16 tiles (%d), both marked (%s)" % [twin_name, up1, str(both_ok)])
			items.queue_free()

	# 2. Job.native_decode parity (true vs false).
	if ClassDB.class_exists("BeltSimNative") and ClassDB.class_exists("BeltLatticeNative"):
		var dec_res := {}
		for ndec in [true, false]:
			BeltItemsScript.State.force_gd = false
			BeltItemsScript.State.lattice_native = true
			BeltItemsScript.Job.native_decode = bool(ndec)
			var items = BeltItemsScript.new()
			add_child(items)
			items._sync = true
			var lm := []
			lm.append_array(_bs_lane(97, 1, 256, 8, 11.0, 10.25, 10.0, 10.25, INF, INF, 81))
			lm.append_array(_bs_lane(81, 5, 128, 8, 11.5, 10.25, 11.0, 10.25, INF, INF, 0))
			lm.append_array(_bs_lane(85, 6, 128, 8, 12.0, 10.25, 11.5, 10.25, INF, INF, 105))
			lm.append_array(_bs_lane(105, 1, 256, 8, 13.0, 10.25, 12.0, 10.25, INF, INF, 0))
			lm.append_array(_bs_lane(121, 1, 256, 8, 21.0, 10.25, 20.0, 10.25, INF, INF, -1))
			var sl := [
				81, 4000, 1, 501, 1, 64, 1,
				85, 4000, 1, 502, 2, 32, 1,
				97, 4000, 2, 503, 1, 64, 1, 504, 1, 192, 1,
				121, 4000, 1, 505, 1, 120, 1,
			]
			var ew := [121, 4000, 505, 120]
			var pc := [97, 4000, 2, 64, 192]
			var pu := [97, 503, 504]
			var of := [15, 0]
			_bs_feed(items, 4000, {"lm": lm, "sl": sl, "ew": ew, "pc": pc, "pu": pu, "of": of}, 1)
			var sl_b := [999, 4001, 1, 599, 1, 10, 1]
			var sh := [81, 4001]
			_bs_feed(items, 4001, {"sl": sl_b, "sh": sh, "dl": [97], "of": [15, 1]}, 1)
			for f in 6:
				_bs_feed(items, 4002 + f, {}, 1)
			var ist: Array = items._state.sim.items_state()
			var ora: Dictionary = items._state.sim.oracle.duplicate(true)
			var asked_n: int = int(items.stats.get("ask_unknown", 0))
			var d105: Array = items.drawn(105)
			var dl85: Array = items.drawn_lattice(85)
			dec_res[ndec] = [ist, ora, asked_n, d105, dl85]
			items.queue_free()
		var a: Array = dec_res[true]
		var b: Array = dec_res[false]
		var match_st: bool = a[0] == b[0] and a[1] == b[1] and int(a[2]) == int(b[2]) and a[3] == b[3] and a[4] == b[4]
		check(match_st,
			"native bs decode parity: C++ apply_bs_body matches GDScript decode (asked %s vs %s, items %s vs %s)" % [
				str(a[2]), str(b[2]), str(a[0]), str(b[0])])

	# 3. Dedicated worker thread vs WorkerThreadPool async completion and teardown.
	BeltItemsScript.State.force_gd = not ClassDB.class_exists("BeltSimNative")
	BeltItemsScript.State.lattice_native = ClassDB.class_exists("BeltLatticeNative")
	for thr in [true, false]:
		BeltItemsScript.job_thread = bool(thr)
		var items = BeltItemsScript.new()
		add_child(items)
		items._sync = false
		var lm: Array = _bs_lane(9, 1, 256, 8, 2.0, 10.0, 1.0, 10.0)
		items.handle({"t": "bs", "k": 5000, "p": 6, "w": 100, "fx": 0, "fy": 2560, "fr": 40,
			"lm": lm, "sl": [9, 5000, 1, 701, 1, 64, 1]})
		var iters := 0
		while iters < 240:
			items._process(1.0 / 60.0)
			if int(items.stats.get("jobs", 0)) >= 1 and not items._job_active():
				break
			OS.delay_msec(5)
			iters += 1
		var jobs_done: int = int(items.stats.get("jobs", 0))
		var st: Array = items._state.sim.items_state()
		var has_items: bool = (st[0] as PackedInt64Array).size() > 0
		remove_child(items)
		var clean_close: bool = items._worker_thread == null
		items.queue_free()
		check(jobs_done >= 1 and not items._job_active() and has_items and clean_close,
			"belt job runner (%s): async job completed in %d iters (%d jobs, %d items, closed=%s)" % [
				"thread" if thr else "pool", iters, jobs_done, (st[0] as PackedInt64Array).size(), str(clean_close)])

	BeltItemsScript.Job.view_cull = was_cull
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.State.lattice_native = was_lat_nat
	BeltLatticeScript.mask_tiled = was_tiled
	BeltItemsScript.Job.native_decode = was_dec
	BeltItemsScript.job_thread = was_thr


## Track 2A Client CPU opts: ProtoDB bitmask + world.fast_add / batched ents joins parity,
## row-run shadow tier incremental parity, far_chunks annulus row-run diff parity, and BeltLods move deadband.


func _belt_lattice_open() -> void:
	BeltItemsScript.Job.view_cull = false
	var was_gd: bool = BeltItemsScript.State.force_gd
	var kept_native: bool = BeltItemsScript.State.lattice_native
	var twins := [[true, false]]
	if ClassDB.class_exists("BeltSimNative") and ClassDB.class_exists("BeltLatticeNative"):
		twins.append([false, true])
	var seen := {}  # [open, twin] -> the exit cell's marks at each phase
	for open in [true, false]:
		for tw: Array in twins:
			BeltItemsScript.State.force_gd = tw[0]
			BeltItemsScript.State.lattice_native = tw[1]
			BeltLatticeScript.mask_open = open
			var marks: Array = []
			var moving_ok := true
			for shift in [0, 16, 32, 48]:
				var items = BeltItemsScript.new()
				add_child(items)
				items._sync = true
				var uvr: Rect2 = items._view_rect()
				var ox := floorf(uvr.get_center().x) - 6.0 if uvr.size.x > 0.0 else 0.0
				var oy := floorf(uvr.get_center().y) + 0.5 if uvr.size.x > 0.0 else 30.0
				# Belt u from x = ox + u to ox + u + 1, items going east (+x) at a yellow belt's 8 a tick; belts 1-8
				# full, belt 9 two items with a gap between (drawn from the simulation), belts 10 and 11 empty.
				var lm: Array = []
				var sl: Array = []
				var id := 100
				for u in range(1, 12):
					lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, ox + u + 1.0, oy, ox + u, oy, INF, INF,
						(u + 1) * 8 + 1 if u < 11 else 0))
					var at: Array = [shift, shift + 64, shift + 128, shift + 192] if u < 9 else [shift + 64, shift + 192] if u == 9 else []
					sl.append_array([u * 8 + 1, 3000, at.size()])
					for q in at:
						sl.append_array([id, 1, q, 1])
						id += 1
				_bs_feed(items, 3000, {"lm": lm, "sl": sl}, 1)
				for f in 24:
					_bs_feed(items, 3001 + f, {}, 1)
				var lat_native: bool = not (items._state.lattice is BeltLatticeScript)
				if not items.lat_mask_has():
					marks.append(null)
					items.queue_free()
					continue
				var lv := -1
				if lat_native:
					lv = int(items._state.lattice.drawn_speed(8 * 8 + 1))
				else:
					var ln8 = items._state.lattice.drawn.get(8 * 8 + 1)
					if ln8 != null:
						lv = int(ln8.v)
				moving_ok = moving_ok and lat_native == bool(tw[1]) and lv == 8
				if lv != 8:
					print("  (the moving gap: belt 8's lattice speed %d, shift %d)" % [lv, shift])
				var cz := posmod(floori(oy * 4.0), 2048)
				# (Belt 8's exit cell, x ox + 8.75 to ox + 9, before belt 9's first; its middle, which stays marked.)
				var exit_cell: bool = items.lat_mask_pixel(posmod(floori((ox + 8.8) * 4.0), 2048), cz)
				var mid: bool = items.lat_mask_pixel(posmod(floori((ox + 8.4) * 4.0), 2048), cz)
				marks.append([exit_cell, mid])

				items.queue_free()
			seen[[open, tw[1]]] = marks
			var what := "%s, %s lattice" % ["open" if open else "--belt-draw-lattice-open=off", "C++" if tw[1] else "GDScript"]
			var n_open := 0
			var all_mid := true
			var made := true
			for mk in marks:
				if mk == null:
					made = false
					continue
				n_open += 0 if mk[0] else 1
				all_mid = all_mid and bool(mk[1])
			check(made and moving_ok and all_mid, "the moving gap (%s): the lattice is made, moving, its middle masked (%s)" % [what, marks])
			if open:
				check(n_open >= 1 and n_open <= 3,
					"the moving gap (%s): the exit cell before a lane drawn from the simulation is left unmarked at the phases the lattice is ahead at, kept at the others (%s)" % [what, marks])
			else:
				check(n_open == 0, "the moving gap (%s): as before, every exit cell marked (%s)" % [what, marks])
	if seen.has([true, true]):
		check(str(seen[[true, true]]) == str(seen[[true, false]]), "the moving gap: the C++ lattice opens the same cells as GDScript's (%s, %s)" % [seen[[true, true]], seen[[true, false]]])
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.State.lattice_native = kept_native
	BeltLatticeScript.mask_open = true
	BeltItemsScript.Job.view_cull = true


## The handover at an open lattice end (belts-handover-clean): with the exit's cell unmarked (--belt-draw-lattice-open)
## the simulation draws the item there, and its slot drew it too, up to 0.125 tile apart (phantoms 1.36% -> 4.01%). On
## (--belt-draw-handover, the default): the exit's slot hides from where its item comes into the cell, so over one
## period it is drawn in that cell only until then; old: all the period. The open scene's belts (eight packed going east
## into a ninth read short), at the phases the lattice is ahead at; both lattices, which agree.


func _belt_lattice_handover() -> void:
	BeltItemsScript.Job.view_cull = false
	var was_gd: bool = BeltItemsScript.State.force_gd
	var kept_native: bool = BeltItemsScript.State.lattice_native
	var twins := [[true, false]]
	if ClassDB.class_exists("BeltSimNative") and ClassDB.class_exists("BeltLatticeNative"):
		twins.append([false, true])
	var seen := {}  # [handover, twin] -> per phase: ticks of 16 the exit cell's slot is drawn, its nearest to the exit
	for hand in [true, false]:
		for tw: Array in twins:
			BeltItemsScript.State.force_gd = tw[0]
			BeltItemsScript.State.lattice_native = tw[1]
			BeltLatticeScript.handover = hand
			var per: Array = []
			for shift in [0, 16, 32, 48]:
				var items = BeltItemsScript.new()
				add_child(items)
				items._sync = true
				var uvr: Rect2 = items._view_rect()
				var ox := floorf(uvr.get_center().x) - 6.0 if uvr.size.x > 0.0 else 0.0
				var oy := floorf(uvr.get_center().y) + 0.5 if uvr.size.x > 0.0 else 30.0
				var lm: Array = []
				var sl: Array = []
				var id := 100
				for u in range(1, 12):
					lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, ox + u + 1.0, oy, ox + u, oy, INF, INF,
						(u + 1) * 8 + 1 if u < 11 else 0))
					var at: Array = [shift, shift + 64, shift + 128, shift + 192] if u < 9 else [shift + 64, shift + 192] if u == 9 else []
					sl.append_array([u * 8 + 1, 3000, at.size()])
					for q in at:
						sl.append_array([id, 1, q, 1])
						id += 1
				_bs_feed(items, 3000, {"lm": lm, "sl": sl}, 1)
				for f in 24:
					_bs_feed(items, 3001 + f, {}, 1)
				var lat_native: bool = not (items._state.lattice is BeltLatticeScript)
				var kks: Array = items._state.lattice.kinds.keys() if not lat_native else items._state.lattice.kind_keys()
				var cz := posmod(floori(oy * 4.0), 2048)
				var open_now: bool = items.lat_mask_has() and not items.lat_mask_pixel(posmod(floori((ox + 8.8) * 4.0), 2048), cz)
				var shown := 0
				var nearest := 0.0
				var kept_drawn: float = items._drawn
				for j in 16:
					items._drawn = kept_drawn + float(j)
					for kk in kks:
						for e in items.drawn_lattice(kk):
							if e == null:
								continue
							var lx: float = (e[0] as Vector3).x - ox
							if lx >= 8.75 and lx < 9.0 and absf((e[0] as Vector3).z - oy) < 0.3:
								shown += 1
								nearest = maxf(nearest, lx)
				items._drawn = kept_drawn
				per.append([open_now, shown, snappedf(nearest, 0.001)])
				items.queue_free()
			seen[[hand, tw[1]]] = per
			var what := "%s, %s lattice" % ["on" if hand else "--belt-draw-handover=old", "C++" if tw[1] else "GDScript"]
			var n_open := 0
			var ok := true
			for e: Array in per:
				if not bool(e[0]):
					continue
				n_open += 1
				# (Its slot slides 8 a tick across the 64 of the cell: two whole periods drawn as before; on, it hides
				# from where its item, d + HAND_SLACK behind it (d at most 32), comes into the cell.)
				ok = ok and (int(e[1]) == 16 if not hand else int(e[1]) >= 2 and int(e[1]) <= 12)
			check(n_open >= 1 and ok, "the handover (%s): at an open exit the slot in its cell is drawn %s (%s)" % [what,
				"only until its item comes into the cell" if hand else "the whole period, as before", per])
	if seen.has([true, true]):
		check(str(seen[[true, true]]) == str(seen[[true, false]]), "the handover: the C++ lattice hides its slots as GDScript's (%s, %s)" % [seen[[true, true]], seen[[true, false]]])
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.State.lattice_native = kept_native
	BeltLatticeScript.handover = true
	BeltItemsScript.Job.view_cull = true



## (tail) A packed block moving along a line of twelve yellow belts (going +x; belts 6-9 read full, the four behind
## known and empty, three ahead to run into): once the block's tail has gone onto belt 6 (the simulation has it short,
## nothing behind; from its first tick here), belt 6 is drawn from the simulation, not as a full lattice till the bridge's next check (the ring of
## tools/belt_ring.py: the lanes a block left drawn full ~100 ticks); the block's other belts stay lattices.
## --belt-draw-lattice-tail=off: as before. belt_sim.gd with the GDScript lattice, and the C++ twins.


func _belt_lattice_tail() -> void:
	BeltItemsScript.Job.view_cull = false
	var was_gd: bool = BeltItemsScript.State.force_gd
	var kept_native: bool = BeltItemsScript.State.lattice_native
	var twins := [[true, false]]
	if ClassDB.class_exists("BeltSimNative") and ClassDB.class_exists("BeltLatticeNative"):
		twins.append([false, true])
	for on in [true, false]:
		for tw: Array in twins:
			BeltItemsScript.State.force_gd = tw[0]
			BeltItemsScript.State.lattice_native = tw[1]
			BeltLatticeScript.tail = on
			var items = BeltItemsScript.new()
			add_child(items)
			items._sync = true
			var uvr: Rect2 = items._view_rect()
			var ox := floorf(uvr.get_center().x) - 6.0 if uvr.size.x > 0.0 else 0.0
			var oy := floorf(uvr.get_center().y) + 0.5 if uvr.size.x > 0.0 else 30.0
			var lm: Array = []
			var sl: Array = []
			var id := 100
			for u in range(1, 13):
				lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, ox + u + 1.0, oy, ox + u, oy, INF, INF, (u + 1) * 8 + 1 if u < 12 else 0))
				var at: Array = [0, 64, 128, 192] if u >= 6 and u <= 9 else []
				sl.append_array([u * 8 + 1, 3000, at.size()])
				for q in at:
					sl.append_array([id, 1, q, 1])
					id += 1
			_bs_feed(items, 3000, {"lm": lm, "sl": sl}, 1)
			var lat = items._state.lattice
			var drawn_at := func(key: int) -> bool:
				return lat.drawn.has(key) if lat is BeltLatticeScript else int(lat.drawn_speed(key)) >= 0
			for f in 4:
				_bs_feed(items, 3001 + f, {}, 1)
			var first: bool = drawn_at.call(65) and drawn_at.call(73)
			for f in range(4, 40):
				_bs_feed(items, 3001 + f, {}, 1)
			var tail_lane: bool = drawn_at.call(49)
			var mid_lane: bool = drawn_at.call(65)
			var what := "%s, %s" % ["on" if on else "--belt-draw-lattice-tail=off", "C++" if tw[1] else "GDScript"]
			check(first and mid_lane and tail_lane == (not on), "the tail (%s): a block's belts drawn as lattices (%s), its tail's belt %s once the tail has gone onto it (%s), a belt it fills still one (%s)" % [
				what, first, "given up" if on else "still drawn full, as before", tail_lane, mid_lane])
			items.queue_free()
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.State.lattice_native = kept_native
	BeltLatticeScript.tail = true
	BeltItemsScript.Job.view_cull = true

## K22 (owner: "breaking a belt with items shows the 3d items in the world for a while"): a belt Zenith takes away
## (`mnd`, `del`: main.gd's belt_removed) loses its lanes and the items drawn on them in the next job, the
## simulation's and the drawing's, not when the bridge's `dl` comes (and then not stood for far icons); its reads
## still on their way don't bring them back. A belt built on its tile in the same frame (a fast-replace) keeps them;
## --belt-sim-removed-now=off as before. K16's replace_at: a lane dropped in the update that brings a lane of the same
## place (a fast-replace's `dl` and `lm`) goes at that lane's read tick, its item carried on, never gone between.
## belt_sim.gd and its C++ twin alike.


func _belt_removed() -> void:
	BeltItemsScript.Job.view_cull = false
	var was_gd: bool = BeltItemsScript.State.force_gd
	var sims := [true]
	if ClassDB.class_exists("BeltSimNative"):
		sims.append(false)
	# Three yellow belts along +x at y 10 (belt u from x = u to u + 1), an item on each: 10 on belt 1, 20 on 2, 30 on 3.
	var lm: Array = []
	for u in [1, 2, 3]:
		lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, u + 1.0, 10.0, u, 10.0))
	var sl0 := [25, 1000, 1, 30, 1, 240, 1, 17, 1000, 1, 20, 1, 220, 1, 9, 1000, 1, 10, 1, 200, 1]
	for force_gd in sims:
		BeltItemsScript.State.force_gd = force_gd
		var what := "belt_sim.gd" if force_gd else "BeltSimNative"
		# (Standing belts here, step 0: the drawn clock, behind the updates, gets to them whenever.)
		var still: Array = []
		for u in [1, 2, 3]:
			still.append_array(_bs_lane(u * 8 + 1, 1, 256, 0, u + 1.0, 10.0, u, 10.0))
		for mode in ["removed", "replaced", "off"]:
			BeltItemsScript.removed_now = mode != "off"
			var items = BeltItemsScript.new()
			add_child(items)
			items._sync = true
			_bs_feed(items, 1000, {"lm": still, "sl": sl0})
			var k := 1001
			while k < 1100 and items.position_of(20) == null:
				_bs_feed(items, k, {})
				k += 1
			var had: bool = items.has_item(20) and items.position_of(20) != null
			items.belt_removed(2, 640, 2560)
			if mode == "replaced":
				items.belt_built(640, 2560)
			_bs_feed(items, k, {})
			_bs_feed(items, k + 1, {})
			var st: Array = items._state.sim.items_state()
			var in_sim := false
			for i in (st[0] as PackedInt64Array).size():
				in_sim = in_sim or int(st[0][i]) == 20 or int(st[1][i]) == 17
			var drawn20: bool = items.has_item(20) or items.position_of(20) != null
			var others: bool = items.has_item(10) and items.has_item(30)
			# (A read of the removed belt made before it went, still on its way: passed over.)
			_bs_feed(items, k + 2, {"lm": _bs_lane(17, 1, 256, 0, 3.0, 10.0, 2.0, 10.0), "sl": [17, k + 2, 1, 21, 1, 100, 1]})
			for f in 30:
				_bs_feed(items, k + 3 + f, {})
			var late: bool = items.has_item(21)
			if mode == "removed":
				check(had and not in_sim and not drawn20 and others and not late,
					"K22 (%s): a belt taken away loses its lanes and items in the next job, the others stay, a late read of it is passed over: had %s, in the simulation %s, drawn %s, the others %s, late read %s"
					% [what, had, in_sim, drawn20, others, late])
			elif mode == "replaced":
				check(had and in_sim and drawn20, "K22 (%s): a belt built on its tile in the same frame (a fast-replace) keeps its items: %s %s" % [what, in_sim, drawn20])
			else:
				check(had and in_sim and drawn20, "K22 (%s): --belt-sim-removed-now=off: as before, its items stay till the bridge's dl: %s %s" % [what, in_sim, drawn20])
			items.queue_free()
		BeltItemsScript.removed_now = true
		# replace_at: at 1006 the update replaces belt 2 (lane 17) by belt 7 (lane 57, the same place), the item 20 on it
		# as the game has it at the new lane's read on 1007, and drops lane 17.
		for on in [true, false]:
			BeltItemsScript.Job.replace_at = on
			var items = BeltItemsScript.new()
			add_child(items)
			items._sync = true
			_bs_feed(items, 1000, {"lm": lm, "sl": sl0})
			for k in range(1001, 1006):
				_bs_feed(items, k, {})
			var missing := 0
			var back := 0.0
			var last_x := -INF
			for k in range(1006, 1030):
				var extra := {}
				if k == 1006:
					extra = {"lm": _bs_lane(57, 1, 256, 8, 3.0, 10.0, 2.0, 10.0), "sl": [57, 1007, 1, 20, 1, 164, 1], "dl": [17]}
				_bs_feed(items, k, extra)
				var d = items.position_of(20)
				if items._drawn < 1003.0:
					continue
				if d == null:
					missing += 1
				else:
					back = maxf(back, last_x - (d as Vector3).x)
					last_x = (d as Vector3).x
			if on:
				check(missing == 0 and back < 0.01, "K16 replace_at (%s): a fast-replaced belt's item goes on onto the new lane, never gone (%d frames) or back (%.3f tiles)"
					% [what, missing, back])
			else:
				print("  (replace_at off, %s: the item missing %d frames, back %.3f tiles)" % [what, missing, back])
			items.queue_free()
		BeltItemsScript.Job.replace_at = true
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.Job.view_cull = true


## A loop whose last belt side-loads onto its own first (one on Aquilo crashed Zenith in the C++
## simulation, reading past an empty list): belt_sim.gd, and its C++ twin when loaded, run it for two
## and a half laps without losing or making an item, the first item over the side-load and round
## again, sparse items 64 or more apart on every lane; packed full, nothing lost either.


func _belt_self_side() -> void:
	var lanes: Array = BeltSimTwins.self_side_loop_lanes()
	var lens := {}
	for l: Array in lanes:
		lens[l[0]] = int(l[2])
	var first_lane: int = lanes[0][0]
	var side_lane: int = lanes[lanes.size() - 1][0]
	var kinds: Array = ["belt_sim.gd"]
	if ClassDB.class_exists("BeltSimNative"):
		kinds.append("BeltSimNative")
	for kind: String in kinds:
		for packed in [false, true]:
			var sim: RefCounted = BeltSimScript.new() if kind == "belt_sim.gd" else ClassDB.instantiate("BeltSimNative")
			sim.edge_mode = BeltSimScript.EDGE_STOP
			sim.ask_on_link = true
			sim.step_to(0)
			for l: Array in lanes:
				sim.callv("set_lane", l)
			var loads: Dictionary = BeltSimTwins.self_side_loop_items(lanes, packed)
			var n := 0
			for key in loads:
				sim.load_lane(key, 0, loads[key])
				n += (loads[key] as PackedInt64Array).size() / 4
			var counts_ok := true
			var inside := true
			var spaced := true
			var crossings := 0
			var was_on := side_lane
			for t in range(1, 900):
				sim.step_to(t)
				var st: Array = sim.items_state()
				var uids: PackedInt64Array = st[0]
				counts_ok = counts_ok and uids.size() == n
				var per := {}
				for i in uids.size():
					var key := int(st[1][i])
					var pos := int(st[2][i])
					inside = inside and lens.has(key) and pos >= 0 and pos < int(lens.get(key, 0))
					var on_lane: Array = per.get(key, [])
					on_lane.append(pos)
					per[key] = on_lane
				if not packed:
					for key in per:
						var ps: Array = per[key]
						ps.sort()
						for i in range(1, ps.size()):
							spaced = spaced and ps[i] - ps[i - 1] >= 64
				var i1 := uids.find(1)
				var on: int = int(st[1][i1]) if i1 >= 0 else -1
				if was_on == side_lane and on == first_lane:
					crossings += 1
				was_on = on
			var what := "packed" if packed else "sparse"
			check(counts_ok and inside and (packed or (spaced and crossings >= 2)),
				"%s: a loop side-loading onto itself (%s) runs 900 ticks, %d items kept (%s), all on their lanes (%s), %s, the first over the side-load %d times"
				% [kind, what, n, counts_ok, inside, "spacing not checked" if packed else "64 apart: %s" % spaced, crossings])


## Items on belts run by the client's own copy of Factorio's belts (belt_sim.gd, `bs`): a first load
## is drawn where the game had it, moving on as the game does; an item flowing along a straight line
## of belts has no new record written; a lane sent again (`sl`) replaces its items at its read tick;
## a drift check that differs asks for the lane again (`bre`); `dl` drops a lane's items; a curve's
## item goes along its arc and an item under the ground isn't drawn; stacks are piles; an update's
## parts go to the simulation together.


func _belt_sim() -> void:
	var items = BeltItemsScript.new()
	add_child(items)
	items._sync = true
	# (Records for every item wherever it is: the scene's camera, from other checks, looks elsewhere
	# than these lanes, and --belt-draw-view would park them. Put back at the end.)
	BeltItemsScript.Job.view_cull = false
	# Five yellow belts in a row along +x at y 10 (belt u from x = u to u + 1), lane 1 each: one line.
	var lm: Array = []
	for u in range(1, 6):
		lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, u + 1.0, 10.0, u, 10.0))
	_bs_feed(items, 1000, {"lm": lm, "sl": [9, 1000, 1, 500, 1, 128, 1]})
	var k := 1000
	var drift_max := 0.0
	var written_mid := -1
	var written_end := -1
	var seen := 0
	for f in 90:
		k += 1
		_bs_feed(items, k, {} if f % 6 == 0 else {}, 1)
		var at = items.position_of(500)
		if at == null or items._drawn < 1000.0:
			continue
		seen += 1
		var want: float = 1.5 + (items._drawn - 1000.0) * 8.0 / 256.0
		drift_max = maxf(drift_max, Vector2((at as Vector3).x, (at as Vector3).z).distance_to(Vector2(want, 10.0)))
		if f == 30:
			written_mid = items.stats["records_written"]
		if f == 80:
			written_end = items.stats["records_written"]
	check(seen > 40 and drift_max < 0.02 and written_mid >= 0 and written_mid == written_end,
		"bs: a first load is drawn where the game had it, moving on as the game does (%d frames, at most %.3f tiles off), and its flow along a straight line writes no new record (%d, %d written)"
		% [seen, drift_max, written_mid, written_end])
	# A lane sent again: its items exactly these at its read tick (a second item behind the first).
	var sl_tick := k + 1
	_bs_feed(items, sl_tick, {"sl": [17, sl_tick, 1, 501, 2, 200, 1]}, 1)
	k += 1
	for f in 16:
		k += 1
		_bs_feed(items, k, {}, 1)
	items.position_of(501)
	_bs_feed(items, k + 1, {}, 1)
	k += 1
	var at501 = items.position_of(501)
	var want501: float = 2.0 + (256.0 - 200.0) / 256.0 + (items._drawn - float(sl_tick)) * 8.0 / 256.0
	check(at501 != null and absf((at501 as Vector3).x - want501) < 0.05 and items.count() == 2,
		"bs sl: a lane sent again gets its items at its read tick (%s, about %.3f)" % [at501, want501])
	# A drift check that differs from what the simulation has asks for the lane again (bre), once.
	var asked_before: int = items.stats["asked"]
	_bs_feed(items, k + 1, {"pc": [33, k + 1, 3, 10, 200]}, 1)
	_bs_feed(items, k + 2, {"pc": [33, k + 2, 3, 10, 200]}, 1)
	k += 2
	for f in 16:
		k += 1
		_bs_feed(items, k, {}, 1)
	check(items.stats["asked"] == asked_before + 1, "bs pc: a drift check that differs asks for the lane again (bre), not again at once (%d)" % [items.stats["asked"] - asked_before])
	# A lane read (sl) or checked (pc) whose meta (lm) never came, its update lost on the way, is asked for
	# again, once (--belt-sim-ask-unknown): the bridge sends a lane's meta only when it loads it.
	asked_before = items.stats["asked"]
	_bs_feed(items, k + 1, {"sl": [777 * 8 + 1, k + 1, 1, 900, 2, 100, 1], "pc": [777 * 8 + 2, k + 1, 0, -1, -1]}, 1)
	_bs_feed(items, k + 2, {"sl": [777 * 8 + 1, k + 2, 1, 900, 2, 92, 1], "pc": [777 * 8 + 2, k + 2, 0, -1, -1]}, 1)
	k += 2
	for f in 4:
		k += 1
		_bs_feed(items, k, {}, 1)
	check(items.stats["asked"] == asked_before + 2 and items.position_of(900) == null,
		"bs: lanes read or checked without their meta are asked for again (bre), once each, and nothing is drawn of them meanwhile (%d)" % [items.stats["asked"] - asked_before])
	# dl: lanes dropped, their items gone (no far icons here to wait for).
	_bs_feed(items, k + 1, {"dl": [9, 17, 25, 33, 41]}, 3)
	k += 1
	check(items.count() == 0, "bs dl: a dropped lane's items go (%d left)" % items.count())
	# A lane leading out of what is sent (lm next -1): its front holds where the bridge last read it
	# (a lane that just ends would let it run up to its end).
	_bs_feed(items, k + 1, {"lm": _bs_lane(301 * 8 + 1, 1, 256, 8, 21.0, 12.0, 20.0, 12.0, INF, INF, -1),
		"sl": [301 * 8 + 1, k + 1, 1, 700, 1, 128, 1]}, 1)
	k += 1
	for f in 30:
		k += 1
		_bs_feed(items, k, {}, 1)
	# (Where the simulation has it: a standing item gets no new record to read a place from.)
	var st700: Array = items._state.sim.items_state()
	var i700 := (st700[0] as PackedInt64Array).find(700)
	var at700: int = int(st700[2][i700]) if i700 >= 0 else -1
	check(at700 == 128, "bs lm next -1: a lane leading out of the square holds its front where it was read (%d)" % at700)
	# ew: its wall alone moves it on (the game's front 64 further at k + 1).
	_bs_feed(items, k + 1, {"ew": [301 * 8 + 1, k + 1, 700, 64]}, 1)
	k += 1
	for f in 12:
		k += 1
		_bs_feed(items, k, {}, 1)
	st700 = items._state.sim.items_state()
	i700 = (st700[0] as PackedInt64Array).find(700)
	at700 = int(st700[2][i700]) if i700 >= 0 else -1
	check(at700 == 64, "bs ew: a lane leading out moves on to the wall it was sent (%d)" % at700)
	_bs_feed(items, k + 1, {"dl": [301 * 8 + 1]}, 3)
	k += 1
	# A curve (a quarter circle about (10, 20), radius 0.734) then an underground's hidden line.
	var r := 0.734
	var clm: Array = []
	clm.append_array(_bs_lane(201 * 8 + 1, 2, 295, 8, 10.0 + r, 20.0, 10.0, 20.0 + r, 10.0 + r * cos(PI / 4.0), 20.0 + r * sin(PI / 4.0)))
	clm.append_array(_bs_lane(202 * 8 + 3, 4, 512, 8, 30.0, 20.0, 28.0, 20.0))
	_bs_feed(items, k + 1, {"lm": clm, "sl": [201 * 8 + 1, k + 1, 1, 600, 1, 290, 1, 202 * 8 + 3, k + 1, 1, 601, 1, 300, 1]}, 1)
	k += 1
	var on_arc := true
	var arc_seen := 0
	var hidden_seen := 0
	for f in 30:
		k += 1
		_bs_feed(items, k, {}, 1)
		var a = items.position_of(600)
		if a != null:
			arc_seen += 1
			var d := Vector2((a as Vector3).x, (a as Vector3).z).distance_to(Vector2(10.0, 20.0))
			on_arc = on_arc and absf(d - r) < 0.02
		if items.has_item(601) and items.position_of(601) == null:
			hidden_seen += 1
	check(arc_seen > 10 and on_arc and hidden_seen > 10,
		"bs: a curve's item goes along its arc (%d frames on it), an item under the ground isn't drawn (%d frames)" % [arc_seen, hidden_seen])
	items.queue_free()
	# Stacks are piles: a stack of 4 is four in one place, a step apart; a single item one.
	var piles = BeltItemsScript.new()
	add_child(piles)
	piles._sync = true
	_bs_feed(piles, 1200, {"lm": _bs_lane(9, 1, 256, 0, 3.0, 0.0, 2.0, 0.0) + _bs_lane(17, 1, 256, 0, 4.0, 0.0, 3.0, 0.0),
		"sl": [9, 1200, 1, 7000, 1, 128, 4, 17, 1200, 1, 7001, 1, 128, 1]}, 3)
	for f in 24:  # (the simulation steps once the drawn clock passes the read tick; looks are made, then written)
		_bs_feed(piles, 1201 + f, {}, 1)
	var drawn_at := func(layer, x: float) -> Array:
		var ys: Array = []
		for e in layer.drawn(1):
			if e != null and absf(e[0].x - x) < 0.01:
				ys.append(snappedf(e[0].y, 0.001))
		ys.sort()
		return ys
	var pile_ys: Array = drawn_at.call(piles, 2.5)
	var single_ys: Array = drawn_at.call(piles, 3.5)
	var pile_ok: bool = pile_ys.size() == 4 and single_ys.size() == 1
	for n in range(1, pile_ys.size()):
		pile_ok = pile_ok and absf(float(pile_ys[n]) - float(pile_ys[n - 1]) - piles._cards.pile_step(1)) < 0.002
	check(pile_ok, "bs: a stack of 4 is a pile of four in one place a step apart (%s), beside a single item (%s)" % [pile_ys, single_ys])
	# Every pile is messy the same way (owner, main's 0.1.4): each copy turned PILE_TURN more than the
	# one below, icon cards and blocks as models (icon piles had stood square, a neat column).
	var turns_at := func(layer, x: float) -> Array:
		var by_y := {}
		for e in layer.drawn(1):
			if e != null and absf(e[0].x - x) < 0.01:
				by_y[snappedf(e[0].y, 0.001)] = snappedf(float(e[1]), 0.0001)
		var ys: Array = by_y.keys()
		ys.sort()
		return ys.map(func(y): return by_y[y])
	var pile_cs: Array = turns_at.call(piles, 2.5)
	var turns_seen := {}
	for c in pile_cs:
		turns_seen[c] = true
	check(pile_cs.size() == 4 and turns_seen.size() == 4,
		"bs: a pile's four copies each turn their own way, cards and blocks too (cosines %s)" % [pile_cs])
	# Every item turns by one rule, ItemCards.turn_for(unique id, copy) (owner, main: lone plastic bars
	# stood square near, turned far): a lone item and a pile's bottom by their own yaw, models, icon
	# cards and blocks alike, each copy PILE_TURN more than the one below; a far icon by its place's
	# seed, the near and far files sharing PILE_TURN.
	var single_cs: Array = turns_at.call(piles, 3.5)
	var use_num: bool = BeltLatticeScript.turn_id and BeltLatticeScript.item_turns
	var fnums: PackedInt32Array = piles._state.sim.lane_fronts(PackedInt64Array([9, 17]), 3)
	var exp_single: float = ItemCardsScript.lattice_turn(fnums[5], BeltLatticeScript.TURN_RUN) if use_num else ItemCardsScript.turn_for(7001)
	var one_rule_ok: bool = pile_cs.size() == 4 and single_cs.size() == 1 and absf(float(single_cs[0]) - cos(exp_single)) < 0.001
	for n in pile_cs.size():
		var exp_pile: float = ItemCardsScript.lattice_turn(fnums[2], BeltLatticeScript.TURN_RUN, n) if use_num else ItemCardsScript.turn_for(7000, n)
		one_rule_ok = one_rule_ok and absf(float(pile_cs[n]) - cos(exp_pile)) < 0.001
	var same_far: Dictionary = BeltLanesScript.Job.build([0, 0, 0, 1, 0], [1], 0.2, [1])
	var same_far_buf: PackedFloat32Array = same_far.get(1, PackedFloat32Array())
	var far_place: int = BeltLanesScript.Job.slot_seed(0, 0, 0, 0)
	one_rule_ok = one_rule_ok and same_far_buf.size() >= ItemCardsScript.STRIDE 		and absf(same_far_buf[0] - cos(ItemCardsScript.turn_for(far_place))) < 0.0001 		and absf(same_far_buf[2] - sin(ItemCardsScript.turn_for(far_place))) < 0.0001 		and is_equal_approx(ItemCardsScript.turn_for(7001), ItemCardsScript.turn_for(7001, 0)) 		and BeltItemsScript.PILE_TURN == ItemCardsScript.PILE_TURN and BeltLanesScript.PILE_TURN == ItemCardsScript.PILE_TURN 		and absf(ItemCardsScript.turn_for(7001)) <= ItemCardsScript.MAX_YAW
	check(one_rule_ok, "bs: one turn rule: a lone item (%s), a pile (%s) and a far icon (%.4f) each turn by ItemCards.turn_for"
		% [single_cs, pile_cs, same_far_buf[0] if same_far_buf.size() > 0 else 9.0])
	piles.queue_free()
	# A lane packed with stacks of 4 drawn as a lattice (--belt-draw-lattice) is a pile of four on every
	# slot, a pile step apart, each copy turned its own way, drawn from its slot's record; with
	# --belt-draw-lattice-pile=off one a slot (the first cut, a stacked bus drawn flat).
	var lat_piles := func(piled: bool) -> Array:
		BeltLatticeScript.piles = piled
		var lat = BeltItemsScript.new()
		add_child(lat)
		lat._sync = true
		var vr: Rect2 = lat._view_rect()
		var lx := floorf(vr.get_center().x) if vr.size.x > 0.0 else 0.0
		var ly := floorf(vr.get_center().y) if vr.size.x > 0.0 else 0.0
		var sl: Array = [9, 1400, 4]
		for j in 4:
			sl.append_array([7100 + j, 1, 32 + 64 * j, 4])
		_bs_feed(lat, 1400, {"lm": _bs_lane(9, 1, 256, 8, lx + 1.0, ly + 0.5, lx, ly + 0.5), "sl": sl}, 3)
		for f in 24:
			_bs_feed(lat, 1401 + f, {}, 1)
		var groups := []
		for when in 2:
			var by_xz := {}
			var lat_kinds: Array = lat._state.lattice.kinds.keys() if lat._state.lattice is BeltLatticeScript else lat._state.lattice.kind_keys()
			for kk in lat_kinds:
				for e in lat.drawn_lattice(kk):
					if e == null:
						continue
					var xz := Vector2(snappedf(e[0].x, 0.001), snappedf(e[0].z, 0.001))
					var g: Array = by_xz.get(xz, [])
					g.append([snappedf(e[0].y, 0.0001), snappedf(float(e[1]), 0.0001)])
					by_xz[xz] = g
			groups.append(by_xz)
			_bs_feed(lat, 1425 + when, {}, 3)
		var step: float = lat._cards.pile_step(1)
		lat.queue_free()
		BeltLatticeScript.piles = true
		return [groups, step]
	var lp: Array = lat_piles.call(true)
	var lat_ok := true
	var lat_said: Array = []
	for by_xz: Dictionary in lp[0]:
		lat_ok = lat_ok and by_xz.size() == 4
		for xz in by_xz:
			var g: Array = by_xz[xz]
			g.sort()
			var cs := {}
			for q in g.size():
				cs[g[q][1]] = true
				if q > 0:
					lat_ok = lat_ok and absf(float(g[q][0]) - float(g[q - 1][0]) - float(lp[1])) < 0.002
			lat_ok = lat_ok and g.size() == 4 and cs.size() == 4
			lat_said.append(g.size())
	var moved: bool = lp[0].size() == 2 and (lp[0][0] as Dictionary).keys() != (lp[0][1] as Dictionary).keys()
	# (Its lane runs into its end and stands: the piles are checked at two moments, moving or not.)
	check(lat_ok, "bs lattice: a lane of stacks of 4 is a pile of four on each of its 4 slots, a pile step apart, each turned its own way, at two moments (piles %s, moved between them %s)" % [lat_said, moved])
	var flat: Array = lat_piles.call(false)
	var flat_n := 0
	for xz in flat[0][0]:
		flat_n += (flat[0][0][xz] as Array).size()
	check((flat[0][0] as Dictionary).size() == 4 and flat_n == 4, "bs lattice: --belt-draw-lattice-pile=off draws one a slot (%d slots, %d drawn)" % [(flat[0][0] as Dictionary).size(), flat_n])
	# An update's parts go to the simulation together.
	var parted = BeltItemsScript.new()
	add_child(parted)
	parted._sync = true
	_bs_feed(parted, 1300, {"part": 1, "parts": 2, "lm": _bs_lane(9, 1, 256, 0, 3.0, 0.0, 2.0, 0.0)}, 2)
	var after_one: int = parted._inbox.size() + parted.count()
	_bs_feed(parted, 1300, {"part": 2, "parts": 2, "sl": [9, 1300, 1, 8000, 1, 100, 1]}, 1)
	for f in 20:
		_bs_feed(parted, 1301 + f, {}, 1)
	check(after_one == 0 and parted.count() == 1, "bs parts: an update waits for all its parts (%d after one of two, %d after both)" % [after_one, parted.count()])
	parted.queue_free()
	# A bridge older than `bs` answers with `bi`: nothing is drawn from it, and the layer says so once a
	# connection (old_bridge; main.gd tells the player), not for every update.
	var old = BeltItemsScript.new()
	add_child(old)
	old._sync = true
	var said := [0]
	old.old_bridge.connect(func() -> void: said[0] += 1)
	old.handle({"t": "bi", "k": 1400, "p": 6, "part": 1, "parts": 1, "l": [900, 1, 512, 2560, 901, 1, 600, 2560]})
	old.handle({"t": "bi", "k": 1406, "p": 6, "part": 1, "parts": 1, "l": [900, 1, 560, 2560]})
	old._process(1.0 / 60.0)
	var said_first: int = said[0]
	old.reset()
	old.handle({"t": "bi", "k": 1412, "p": 6, "part": 1, "parts": 1, "l": []})
	check(said_first == 1 and said[0] == 2 and old.count() == 0 and old._inbox.is_empty(),
		"bs: a bridge sending `bi` (older than `bs`) is reported once a connection (%d, %d after a reset) and draws nothing (%d items)" % [said_first, said[0], old.count()])
	old.queue_free()
	BeltItemsScript.Job.view_cull = true


## Unison (owner): a backed-up line moves as one block. When its front gets room every item of the run
## moves the same tick, so no gap opens between them: their records all start together, and a lattice
## (lanes drawn packed) takes the new speed on every lane of the run in the same job. A closed loop
## full of mixed items circulates as an unbroken ring.


func _belt_unison() -> void:
	var items = BeltItemsScript.new()
	add_child(items)
	items._sync = true
	BeltItemsScript.Job.view_cull = false
	# (Placed in the client's planned ground, as the lattice draws only lanes there: since main's
	# camera-led view the headless test's ground no longer reaches y 30.)
	var uvr: Rect2 = items._view_rect()
	var ox := floorf(uvr.get_center().x) - 3.0 if uvr.size.x > 0.0 else 0.0
	var oy := floorf(uvr.get_center().y) + 0.5 if uvr.size.x > 0.0 else 30.0
	# Four yellow belts along +x at y oy (belt u from x = ox + u to ox + u + 1), the last leading out of what is
	# sent (lm next -1: its front holds where the bridge read it), packed solid: 15 items 64 apart,
	# the front one 96 from the end.
	var lm: Array = []
	for u in range(1, 4):
		lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, ox + u + 1.0, oy, ox + u, oy))
	lm.append_array(_bs_lane(4 * 8 + 1, 1, 256, 8, ox + 5.0, oy, ox + 4.0, oy, INF, INF, -1))
	var sl: Array = []
	var uids := PackedInt64Array()
	for u in range(4, 0, -1):
		var n := 3 if u == 4 else 4
		sl.append_array([u * 8 + 1, 2000, n])
		for q in n:
			var uid := 3000 + uids.size()
			uids.append(uid)
			sl.append_array([uid, 1, (q + (1 if u == 4 else 0)) * 64 + 32, 1])
	_bs_feed(items, 2000, {"lm": lm, "sl": sl}, 1)
	var xs_of := func() -> Array:
		var xs: Array = []
		for uid in uids:
			var at = items.position_of(uid)
			if at != null:
				xs.append((at as Vector3).x)
		xs.sort()
		return xs
	# (position_of watches an item from the next job on: a few frames first.)
	var k := 2000
	for f in 24:
		k += 1
		_bs_feed(items, k, {}, 1)
		xs_of.call()
	var before: Array = xs_of.call()
	# The wall moves on 64 at tick k + 1: the whole run moves one gap, together.
	_bs_feed(items, k + 1, {"ew": [4 * 8 + 1, k + 1, 3000, 32]}, 1)
	k += 1
	var worst_gap := 0.0
	var moved_apart := 0.0  # the most the front and the back items' moves differed, over the frames
	var frames_seen := 0
	var lat_split := 0  # frames on which the run's lattice lanes had different speeds
	var lat_frames := 0
	# (The lanes' lattice speeds: belt_lattice.gd's drawn[key].v, or BeltLatticeNative.drawn_speed.)
	var lat_native: bool = not (items._state.lattice is BeltLatticeScript)
	var lattice: Dictionary = {} if lat_native else items._state.lattice.drawn
	for f in 30:
		k += 1
		_bs_feed(items, k, {}, 1)
		var xs: Array = xs_of.call()
		if xs.size() != uids.size():
			continue
		frames_seen += 1
		for i in range(1, xs.size()):
			worst_gap = maxf(worst_gap, absf(float(xs[i]) - float(xs[i - 1]) - 0.25))
		moved_apart = maxf(moved_apart, absf((float(xs[0]) - float(before[0])) - (float(xs[xs.size() - 1]) - float(before[before.size() - 1]))))
		var vs := {}
		for u in range(1, 5):
			if lat_native:
				var lv: int = items._state.lattice.drawn_speed(u * 8 + 1)
				if lv >= 0:
					vs[lv] = true
				continue
			var ln = lattice.get(u * 8 + 1)
			if ln != null:
				vs[ln.v] = true
		if vs.size() > 0:
			lat_frames += 1
			if vs.size() > 1:
				lat_split += 1
	var after: Array = xs_of.call()
	var moved: float = (float(after[0]) - float(before[0])) if after.size() > 0 and before.size() > 0 else 0.0
	check(frames_seen >= 20 and worst_gap < 0.01 and moved_apart < 0.01 and absf(moved - 0.25) < 0.01,
		"bs unison: a backed-up run moves one gap as one block when its front gets room (%d frames; spacing off by at most %.3f tile, front and back moved alike within %.3f, moved %.3f)"
		% [frames_seen, worst_gap, moved_apart, moved])
	check(lat_frames > 0 and lat_split == 0, "bs unison: the run's lattice lanes take a new speed in the same job (%d of %d frames split)" % [lat_split, lat_frames])
	items.queue_free()
	# A closed loop: four lanes round a square (10..11, 40..41), each lane's exit the next one's entry,
	# full of two kinds in turn (16 items 64 apart). It circulates as a ring: every gap stays 0.25 tile.
	var loop = BeltItemsScript.new()
	add_child(loop)
	loop._sync = true
	var corners := [Vector2(10, 40), Vector2(11, 40), Vector2(11, 41), Vector2(10, 41)]
	var llm: Array = []
	var lsl: Array = []
	var luids := PackedInt64Array()
	for i in 4:
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % 4]
		llm.append_array(_bs_lane((20 + i) * 8 + 1, 1, 256, 8, b.x, b.y, a.x, a.y))
		lsl.append_array([(20 + i) * 8 + 1, 2100, 4])
		for q in 4:
			var uid := 4000 + luids.size()
			luids.append(uid)
			lsl.append_array([uid, 1 + (luids.size() % 2), q * 64 + 32, 1])
	_bs_feed(loop, 2100, {"lm": llm, "sl": lsl}, 1)
	k = 2100
	for f in 4:
		k += 1
		_bs_feed(loop, k, {}, 1)
		for uid in luids:
			loop.position_of(uid)
	var ring_s := func(p: Vector3) -> float:
		# Along the ring from (10, 40) clockwise: the side the point is on, then how far along it.
		var ds := [absf(p.z - 40.0), absf(p.x - 11.0), absf(p.z - 41.0), absf(p.x - 10.0)]
		var side := 0
		for i in range(1, 4):
			if ds[i] < ds[side]:
				side = i
		match side:
			0: return p.x - 10.0
			1: return 1.0 + (p.z - 40.0)
			2: return 2.0 + (11.0 - p.x)
			_: return 3.0 + (41.0 - p.z)
	var ring_gap := 0.0
	var ring_worst := ""
	var ring_frames := 0
	var first_s := -1.0
	var last_s := -1.0
	for f in 120:
		k += 1
		_bs_feed(loop, k, {}, 1)
		var ss: Array = []
		for uid in luids:
			var at = loop.position_of(uid)
			if at != null:
				ss.append(ring_s.call(at as Vector3))
		if ss.size() != luids.size():
			continue
		ss.sort()
		ring_frames += 1
		for i in ss.size():
			var g: float = float(ss[(i + 1) % ss.size()]) - float(ss[i])
			if i == ss.size() - 1:
				g += 4.0
			if absf(g - 0.25) > ring_gap:
				ring_gap = absf(g - 0.25)
				ring_worst = "frame %d, drawn %.3f, between %.3f and %.3f" % [f, loop._drawn, ss[i], ss[(i + 1) % ss.size()]]
		var s0 = loop.position_of(luids[0])
		if s0 != null:
			if first_s < 0.0:
				first_s = ring_s.call(s0 as Vector3)
			last_s = ring_s.call(s0 as Vector3)
	var went: float = fposmod(last_s - first_s, 4.0)
	# (0.03: a residue of 6/256 at the ring's cut remains, under a tenth of a gap; a job-late crossing was 0.031 a
	# tick, 0.8 tile a job in the live client.)
	check(ring_frames >= 100 and ring_gap < 0.03 and went > 1.0,
		"bs unison: a full closed loop of mixed items circulates as an unbroken ring (%d frames; gaps off by at most %.3f tile at %s; an item went %.2f tiles round)" % [ring_frames, ring_gap, ring_worst, went])
	loop.queue_free()
	BeltItemsScript.Job.view_cull = true


## K14 (owner: "items change their orientation as they move on the belts, looks really off"): a packed
## lane is drawn as a lattice (belt_lattice.gd) whose slots slide a gap and wrap back, the slot ahead
## taking the item on, so a turn kept per slot changed every item's turn each quarter tile. One item seen
## sliding round a packed ring keeps its turn over many slides and from belt to belt (corners too), the
## lane's items still turning their own ways; one in a packed run keeps it as the run starts and stops.
## Both lattices (belt_lattice.gd and BeltLatticeNative); --belt-draw-lattice-turns=slot (the old per-slot
## turns) changes the item's turn, as the owner saw.


func _belt_lattice_turns() -> void:
	var kept_native: bool = BeltItemsScript.State.lattice_native
	var natives := [false]
	if ClassDB.class_exists("BeltLatticeNative") and ClassDB.class_exists("BeltSimNative"):
		natives.append(true)
	var drawn_by: Array = []  # each twin's ring: its items' turns (cosines, sorted)
	for native: bool in natives:
		BeltItemsScript.State.lattice_native = native
		var twin := "C++" if native else "GDScript"
		var ring: Array = _lattice_turns_ring(true)
		check(ring[0] >= 140 and ring[1] == 1 and ring[2] > 4.0 and ring[3] >= 16,
			"K14 %s lattice: an item sliding round a packed ring keeps one turn (%d frames, %d turns seen, went %.2f tiles: %d slides and 4 belts), the ring's 32 items turned %d ways"
			% [twin, ring[0], ring[1], ring[2], int(ring[2] * 4.0), ring[3]])
		drawn_by.append(ring[4])
		var slots: Array = _lattice_turns_ring(false)
		check(slots[0] >= 140 and slots[1] > 4,
			"K14 %s lattice: with --belt-draw-lattice-turns=slot the same item takes a new turn as it slides (%d turns over %d frames)" % [twin, slots[1], slots[0]])
		# (K19's --belt-draw-lattice-settle leaves a standing lattice where it is while its run moves on one
		# gap: the start and stop of a one-gap move are K14's own with it off; with it on the lattice stands,
		# and a run that moves on for longer than the settle time starts and stops with its turns kept.)
		BeltLatticeScript.settle = false
		var run: Array = _lattice_turns_run()
		check(run[0] >= 40 and run[1] == 1 and run[2] > 0.2,
			"K14 %s lattice: (settle off) an item in a packed run keeps its turn as the run moves on a gap and stops (%d frames, %d turns, moved %.3f)" % [twin, run[0], run[1], run[2]])
		BeltLatticeScript.settle = true
		var stood: Array = _lattice_turns_run()
		check(stood[0] >= 40 and stood[1] == 1 and stood[2] < 0.02,
			"K19 %s lattice: a packed run moving on one gap leaves its lattice standing, the item's turn kept (%d frames, %d turns, moved %.3f)" % [twin, stood[0], stood[1], stood[2]])
		var flow: Array = _lattice_turns_run(3)
		check(flow[0] >= 40 and flow[1] == 1 and flow[2] > 0.2,
			"K14 and K19 %s lattice: a run moving on three gaps starts once it has moved for longer than a closing hole, and stops, the item's turn kept (%d frames, %d turns, moved %.3f)" % [twin, flow[0], flow[1], flow[2]])
	if drawn_by.size() == 2:
		var same: bool = (drawn_by[0] as Array).size() == (drawn_by[1] as Array).size() and (drawn_by[0] as Array).size() >= 32
		for i in (drawn_by[0] as Array).size() if same else 0:
			same = same and absf(float(drawn_by[0][i]) - float(drawn_by[1][i])) < 0.0001
		check(same, "K14: the GDScript and C++ lattices turn the ring's items alike (%d and %d drawn)" % [(drawn_by[0] as Array).size(), (drawn_by[1] as Array).size()])
	BeltItemsScript.State.lattice_native = kept_native
	BeltLatticeScript.item_turns = true
	BeltLatticeScript.settle = true


## (_belt_lattice_turns) Follows the drawn lattice item nearest `at` for `frames` frames (a tick each): each
## frame the one nearest where it would be had it gone on as in the frame before (a lane that stops or
## starts jumps by up to half a gap as it is drawn), its turns (cosines) gathered in `turns`. Returns
## [frames followed, distinct turns seen, tiles moved, at].


func _follow_lattice_item(items, at: Vector2, frames: int, k: int, turns := {}) -> Array:
	var followed := 0
	var moved := 0.0
	var reach := 0.14
	var step := Vector2.ZERO
	for f in frames:
		k += 1
		_bs_feed(items, k, {}, 1)
		var best := INF
		var best_at := at
		var best_c := 0.0
		var kinds: Array = items._state.lattice.kinds.keys() if items._state.lattice is BeltLatticeScript else items._state.lattice.kind_keys()
		for kk in kinds:
			for e in items.drawn_lattice(kk):
				if e == null:
					continue
				var p := Vector2((e[0] as Vector3).x, (e[0] as Vector3).z)
				if p.distance_to(at + step) < best:
					best = p.distance_to(at + step)
					best_at = p
					best_c = float(e[1])
		if best > reach:
			break
		moved += best_at.distance_to(at)
		if best_at.distance_to(at) < 0.06:
			step = best_at - at  # (its own motion: a lane's jump isn't one)
		at = best_at
		followed += 1
		turns[snappedf(best_c, 0.0001)] = true
	return [followed, turns.size(), moved, at]


## A ring of eight packed yellow belts (two a side of a 2 x 2 square, in the lattice's planned ground) full
## of one kind circulating: one item followed for 150 ticks from the middle of the first belt. Returns
## [frames followed, distinct turns, tiles moved, the ring's distinct turns at the end, every drawn item's
## turn then (cosines, sorted)].


func _lattice_turns_ring(item_turns: bool) -> Array:
	BeltLatticeScript.item_turns = item_turns
	BeltItemsScript.Job.view_cull = false
	var items = BeltItemsScript.new()
	add_child(items)
	items._sync = true
	var vr: Rect2 = items._view_rect()
	var ox := floorf(vr.get_center().x) - 1.0 if vr.size.x > 0.0 else 0.0
	var oy := floorf(vr.get_center().y) - 1.0 if vr.size.x > 0.0 else 0.0
	# Clockwise from (ox, oy): east along the top, south, west along the bottom, north.
	var points: Array = []
	for i in 2:
		points.append(Vector2(ox + i, oy))
	for i in 2:
		points.append(Vector2(ox + 2.0, oy + i))
	for i in 2:
		points.append(Vector2(ox + 2.0 - i, oy + 2.0))
	for i in 2:
		points.append(Vector2(ox, oy + 2.0 - i))
	var lm: Array = []
	var sl: Array = []
	for i in 8:
		var a: Vector2 = points[i]
		var b: Vector2 = points[(i + 1) % 8]
		var key := (60 + i) * 8 + 1
		lm.append_array(_bs_lane(key, 1, 256, 8, b.x, b.y, a.x, a.y))
		sl.append_array([key, 3000, 4])
		for q in 4:
			sl.append_array([9000 + i * 4 + q, 1, q * 64 + 32, 1])
	_bs_feed(items, 3000, {"lm": lm, "sl": sl}, 1)
	var k := 3000
	for f in 24:  # (the looks, then the lattice)
		k += 1
		_bs_feed(items, k, {}, 1)
	var got := _follow_lattice_item(items, Vector2(ox + 0.5, oy), 150, k)
	var ring_turns := {}
	var all_turns: Array = []
	var kinds: Array = items._state.lattice.kinds.keys() if items._state.lattice is BeltLatticeScript else items._state.lattice.kind_keys()
	for kk in kinds:
		for e in items.drawn_lattice(kk):
			if e != null:
				ring_turns[snappedf(float(e[1]), 0.0001)] = true
				all_turns.append(float(e[1]))
	all_turns.sort()
	items.queue_free()
	BeltItemsScript.Job.view_cull = true
	BeltLatticeScript.item_turns = true
	return [got[0], got[1], got[2], ring_turns.size(), all_turns]


## Four yellow belts in a row, the last leading out of what is sent (its front held where the bridge read it),
## the three behind packed (the lattice) and standing; the wall moves on `gaps` gaps, so the run moves that
## far as one block and stands again (as _belt_unison's). One item on the second belt followed. Returns
## [frames followed, distinct turns, tiles moved].


func _lattice_turns_run(gaps := 1) -> Array:
	BeltItemsScript.Job.view_cull = false
	var items = BeltItemsScript.new()
	add_child(items)
	items._sync = true
	var vr: Rect2 = items._view_rect()
	var ox := floorf(vr.get_center().x) - 3.0 if vr.size.x > 0.0 else 0.0
	var oy := floorf(vr.get_center().y) + 0.5 if vr.size.x > 0.0 else 30.0
	var lm: Array = []
	for u in range(1, 4):
		lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, ox + u + 1.0, oy, ox + u, oy))
	lm.append_array(_bs_lane(4 * 8 + 1, 1, 256, 8, ox + 5.0, oy, ox + 4.0, oy, INF, INF, -1))
	var sl: Array = []
	var uid := 3500
	for u in range(4, 0, -1):
		var n := 3 if u == 4 else 4
		sl.append_array([u * 8 + 1, 3200, n])
		for q in n:
			sl.append_array([uid, 1, (q + (1 if u == 4 else 0)) * 64 + 32, 1])
			uid += 1
	_bs_feed(items, 3200, {"lm": lm, "sl": sl}, 1)
	var k := 3200
	for f in 24:
		k += 1
		_bs_feed(items, k, {}, 1)
	# (Standing: the item 0.375 into the second belt, then the wall moves on and the run with it.)
	var turns := {}
	var start := _follow_lattice_item(items, Vector2(ox + 2.0 + 0.375, oy), 8, k, turns)
	k += 8
	# (`gaps` > 1: the wall is the item that many behind the front, those ahead of it running off: the run
	# moves on that many gaps without stopping.)
	_bs_feed(items, k + 1, {"ew": [4 * 8 + 1, k + 1, 3500 + gaps - 1, 32]}, 1)
	k += 1
	var got := _follow_lattice_item(items, start[3], 40 + 8 * (gaps - 1), k, turns)
	items.queue_free()
	BeltItemsScript.Job.view_cull = true
	return [int(start[0]) + int(got[0]), turns.size() if start[0] > 0 and got[0] > 0 else 0, got[2]]


## G11, G14: Gleba's and Aquilo's ground. Water is told by its collision mask (the wetlands, the
## deep lake, brash ice, the ammoniacal ocean), `layer = gleba_tile_offset + 8` is worked out so
## the planets' tiles blend in Factorio's order, the water shaders' own pictures fill the swamps
## and brash ice, and a surface change makes room in the layer table.


func _track2a_cpu_opts() -> void:
	var was_fast: bool = WorldMirror.fast_add
	var was_shadow_runs: bool = WorldMirror.shadow_row_runs
	var was_far_runs: bool = FarChunks.decide_row_runs
	var was_belt_deadband: bool = BeltLods.move_deadband
	var prev_cam := get_viewport().get_camera_3d()

	# 1. ProtoDB.PF_* bitmask consistency and world.fast_add / batched ents join parity.
	var pf_ok := true
	for rt: String in ModelLibrary.REMNANT_TYPES:
		pf_ok = pf_ok and (ProtoDB.flags_for_type(rt) & ProtoDB.PF_REMNANT) != 0
	for ct: String in ModelLibrary.CARGO_TYPES:
		pf_ok = pf_ok and (ProtoDB.flags_for_type(ct) & ProtoDB.PF_CARGO) != 0
	for bt: String in WorldMirror.BELT_TYPES:
		pf_ok = pf_ok and (ProtoDB.flags_for_type(bt) & ProtoDB.PF_BELT) != 0
	for bt: String in WorldMirror.CAPPED_TYPES:
		pf_ok = pf_ok and (ProtoDB.flags_for_type(bt) & ProtoDB.PF_BELT_CAPPED) != 0
	check(pf_ok and (ProtoDB.flags_for_type("wall") & ProtoDB.PF_WALL) != 0
		and (ProtoDB.flags_for_type("gate") & ProtoDB.PF_GATE) != 0
		and (ProtoDB.flags_for_type("pipe") & ProtoDB.PF_PIPE_PLAIN) != 0
		and (ProtoDB.flags_for_type("assembling-machine") & (ProtoDB.PF_WALL_ANY | ProtoDB.PF_BELT | ProtoDB.PF_PIPE_ANY | ProtoDB.PF_CARGO | ProtoDB.PF_REMNANT)) == 0,
		"ProtoDB PF_* bitmask flags match WorldMirror and ModelLibrary categories")

	var test_protos := [
		[1, "stone-wall", "wall", -0.5, -0.5, 0.5, 0.5, 180, 180, 180, 1, 1],
		[2, "gate", "gate", -0.5, -0.5, 0.5, 0.5, 160, 160, 160, 1, 1],
		[3, "pipe", "pipe", -0.5, -0.5, 0.5, 0.5, 100, 140, 200, 1, 1],
		[4, "pipe-to-ground", "pipe-to-ground", -0.5, -0.5, 0.5, 0.5, 100, 140, 200, 1, 1],
		[5, "transport-belt", "transport-belt", -0.5, -0.5, 0.5, 0.5, 220, 180, 40, 1, 1],
		[6, "cargo-landing-pad", "cargo-landing-pad", -4.0, -4.0, 4.0, 4.0, 120, 120, 140, 8, 8],
		[7, "cargo-bay", "cargo-bay", -2.0, -2.0, 2.0, 2.0, 130, 130, 150, 4, 4],
		[8, "small-remnants", "corpse", -0.5, -0.5, 0.5, 0.5, 90, 90, 90, 1, 1],
		[9, "assembling-machine-1", "assembling-machine", -1.5, -1.5, 1.5, 1.5, 80, 120, 160, 3, 3],
		[10, "entity-ghost", "entity-ghost", -2.0, -2.0, 2.0, 2.0, 150, 190, 255, 4, 4],
	]
	var snap_of := func(w: WorldMirror) -> Dictionary:
		var out := {"wc": {}, "pc": {}, "pw": {}, "be": {}, "cb": {}, "rem": w._remnants.size(), "pipes": w._pipes.size(), "walls": w._walls.size()}
		for k in w.entities:
			var rec: WorldMirror.Rec = w.entities[k]
			if rec.extra.has("wc"):
				out["wc"][k] = int(rec.extra["wc"])
			if rec.extra.has("pc"):
				out["pc"][k] = int(rec.extra["pc"])
			if rec.extra.has("pw"):
				out["pw"][k] = int(rec.extra["pw"])
			if rec.belt_ends != 0:
				out["be"][k] = rec.belt_ends
			if rec.extra.has("cb"):
				out["cb"][k] = int(rec.extra["cb"])
		return out
	var fast_snaps := {}
	for fast in [true, false]:
		WorldMirror.fast_add = bool(fast)
		var w := WorldMirror.new()
		add_child(w)
		w.protos.add_entities(test_protos)
		var cv := ChunkView.new()
		cv.coord = Vector2i(0, 0)
		w.chunks[cv.coord] = cv
		w.add_child(cv)
		# Batch 1: pc_mod pipes (even + odd tile), walls 2x2 + gate, belts, cargo hub + bay + ghost, remnant, assembler.
		w.handle({"t": "ents", "cx": 0, "cy": 0, "part": 1, "e": [
			[101, 1, 128, 128, 0], [102, 1, 384, 128, 0], [103, 1, 128, 384, 0], [104, 1, 384, 384, 0],
			[105, 2, 640, 128, 4],
			[106, 3, 128, 1152, 0, {"pc": 2}], [107, 3, 384, 1152, 0, {"pc": 8}],
			[108, 5, 128, 1664, 4], [109, 5, 384, 1664, 4],
			[110, 6, 3072, 3072, 0], [111, 7, 4608, 3072, 0],
			[112, 10, 4608, 4096, 0, {"gh": 7}],
			[113, 8, 256, 2560, 0], [114, 9, 1024, 2560, 0],
		]})
		var s1: Dictionary = snap_of.call(w)
		# Batch 2: legacy pipes (no pc_mod) to exercise mixed local pipe fallback.
		w.handle({"t": "ents", "cx": 0, "cy": 0, "part": 2, "e": [
			[120, 3, 2176, 1152, 0], [121, 4, 2432, 1152, 12],
		]})
		var s2: Dictionary = snap_of.call(w)
		fast_snaps[fast] = [s1, s2, w.pipe_at(Vector2i(0, 4)) != null]
		w.queue_free()
	var fa: Array = fast_snaps[true]
	var fb: Array = fast_snaps[false]
	check(fa == fb, "world.fast_add parity: batched PF_* path matches unbatched path (%s vs %s)" % [str(fa[1]), str(fb[1])])

	# 2. Row-run shadow tiers & FarChunks annulus diff parity.
	var cam := Camera3D.new()
	cam.fov = 35.0
	add_child(cam)
	cam.current = true
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, -30.0, 0.0)
	sun.directional_shadow_max_distance = 150.0
	sun.shadow_enabled = true
	add_child(sun)

	var sh_worlds := {}
	for sr in [true, false]:
		var sw := WorldMirror.new()
		sw.sun = sun
		add_child(sw)
		for y in range(-8, 9):
			for x in range(-8, 9):
				var c := Vector2i(x, y)
				var scv := ChunkView.new()
				scv.coord = c
				scv.loaded = true
				sw.chunks[c] = scv
				sw._row_add(c, scv)
				sw.far_chunks.note_added(c)
				sw._shadow_fresh.append(scv)
				sw._shadow_uncounted[c] = true
				sw.add_child(scv)
		sh_worlds[sr] = sw

	var fc_worlds := {}
	for fr in [true, false]:
		var fw := WorldMirror.new()
		add_child(fw)
		for y in range(-8, 9):
			for x in range(-8, 9):
				var c := Vector2i(x, y)
				var fcv := ChunkView.new()
				fcv.coord = c
				fcv.loaded = true
				fw.chunks[c] = fcv
				fw._row_add(c, fcv)
				fw.far_chunks.note_added(c)
				fw.add_child(fcv)
		fc_worlds[fr] = fw

	var shadow_match := true
	var far_match := true
	var unloaded_step := false
	for step in 14:
		var fx := float(step) * 14.0 - 40.0
		var fz := float(step % 5) * 18.0 - 36.0
		cam.look_at_from_position(Vector3(fx + 14.0, 26.0 + float(step % 3) * 8.0, fz + 18.0), Vector3(fx, 0.0, fz))
		for sr in [true, false]:
			WorldMirror.shadow_row_runs = bool(sr)
			var sw: WorldMirror = sh_worlds[sr]
			sw.set_focus(Vector2(fx, fz))
			sw.shadow_usec = 1 << 40
			if step == 7:
				sw._unload(Vector2i(1, 0))
				unloaded_step = true
			sw._update_shadow_casters()
		var sw_t: WorldMirror = sh_worlds[true]
		var sw_f: WorldMirror = sh_worlds[false]
		if sw_t.shadow_casters != sw_f.shadow_casters:
			shadow_match = false
		for c in sw_t.chunks:
			if (sw_t.chunks[c] as ChunkView).shadow_tier != (sw_f.chunks[c] as ChunkView).shadow_tier:
				shadow_match = false
				break

		for fr in [true, false]:
			FarChunks.decide_row_runs = bool(fr)
			var fw: WorldMirror = fc_worlds[fr]
			fw.set_focus(Vector2(fx, fz))
			var fc: FarChunks = fw.far_chunks
			if step == 7 and fw.chunks.has(Vector2i(1, 0)):
				fw._unload(Vector2i(1, 0))
			fc._check_timer = FarChunks.CHECK_INTERVAL
			fc._decide(1.0)
			while fc._pass_next < fc._pass_todo.size():
				fc._decide_slice()
		var fw_t: WorldMirror = fc_worlds[true]
		var fw_f: WorldMirror = fc_worlds[false]
		if fw_t.far_chunks._far_count != fw_f.far_chunks._far_count:
			far_match = false
		for c in fw_t.chunks:
			if (fw_t.chunks[c] as ChunkView).far.far != (fw_f.chunks[c] as ChunkView).far.far:
				far_match = false
				break
	check(shadow_match and unloaded_step, "shadow row runs: exact shadow tiers & shadow_casters match across 14 camera steps + unload")
	check(far_match, "far chunks annulus runs: exact far state & _far_count match across 14 camera steps + unload")

	# 3. BeltLods move deadband check.
	BeltLods._last_view = []
	BeltLods._dirty = false
	BeltLods._timer = BeltLods.CHECK_INTERVAL
	cam.look_at_from_position(Vector3(10.0, 20.0, 10.0), Vector3(10.0, 0.0, 0.0))
	BeltLods.move_deadband = true
	BeltLods.update(null, cam, 0.0)
	BeltLods._timer = 0.01
	cam.global_position = Vector3(10.2, 20.0, 10.0)
	cam.rotate_y(0.1)
	BeltLods.update(null, cam, 0.01)
	var skipped_nudge := BeltLods._timer > 0.005
	cam.global_position = Vector3(16.0, 20.0, 10.0)
	BeltLods.update(null, cam, 0.01)
	var ran_big_move := is_zero_approx(BeltLods._timer)
	BeltLods._timer = 0.01
	BeltLods.move_deadband = false
	cam.rotate_y(0.05)
	BeltLods.update(null, cam, 0.01)
	var ran_no_deadband := is_zero_approx(BeltLods._timer)
	check(skipped_nudge and ran_big_move and ran_no_deadband,
		"BeltLods move deadband: sub-2-tile nudge/turn skipped (%s), big move ran (%s), off ran (%s)" % [
			str(skipped_nudge), str(ran_big_move), str(ran_no_deadband)])

	for sw in sh_worlds.values():
		(sw as WorldMirror).queue_free()
	for fw in fc_worlds.values():
		(fw as WorldMirror).queue_free()
	sun.queue_free()
	cam.queue_free()
	if prev_cam != null and is_instance_valid(prev_cam):
		prev_cam.current = true
	await get_tree().process_frame
	BeltLods._last_view = []
	WorldMirror.fast_add = was_fast
	WorldMirror.shadow_row_runs = was_shadow_runs
	FarChunks.decide_row_runs = was_far_runs
	BeltLods.move_deadband = was_belt_deadband


func _track2b_streaming_and_prep() -> void:
	var was_sub_inc := WorldMirror.sub_incremental
	var was_sq := Bridge.square_subs
	var was_rec_cache := ChunkView.build_rec_cache
	var was_mm_worker := ChunkView.chunk_mm_worker
	var prev_cam := get_viewport().get_camera_3d()

	var cam := Camera3D.new()
	add_child(cam)
	cam.current = true
	cam.look_at_from_position(Vector3(0.0, 24.0, 20.0), Vector3(0.0, 0.0, 0.0))

	Bridge.square_subs = 50
	var wi := WorldMirror.new()
	var wl := WorldMirror.new()
	wi.name = "SubInc"
	wl.name = "SubLeg"
	wi.view_radius = 6
	wl.view_radius = 6
	wi.hold_min_free = 0
	wl.hold_min_free = 0
	add_child(wi)
	add_child(wl)

	# 1. sub_incremental vs legacy parity + lazy _wanted/_subscribed + square_rows_from_rows + prio warm
	var steps: Array = [
		[Vector2(16.0, 16.0), Vector3(0.0, 0.0, -10.0), false, false, false],
		[Vector2(16.0, 16.0), Vector3(0.0, 0.0, -10.0), true, false, false],
		[Vector2(16.0, 16.0), Vector3(0.0, 0.0, -10.0), true, false, false],
		[Vector2(16.0, 16.0), Vector3(0.0, 0.0, -10.0), true, false, false],
		[Vector2(16.0, 16.0), Vector3(0.0, 0.0, -10.0), true, false, false],
		[Vector2(48.0, 16.0), Vector3(10.0, 0.0, 0.0), true, false, false],
		[Vector2(80.0, 48.0), Vector3(10.0, 0.0, 8.0), true, false, false],
		[Vector2(112.0, 48.0), Vector3(-10.0, 0.0, 0.0), true, false, false],
		[Vector2(80.0, 48.0), Vector3(-10.0, 0.0, 0.0), true, false, false],  # walk back into warm rings
		[Vector2(48.0, 16.0), Vector3(-10.0, 0.0, -8.0), true, false, false],
		[Vector2(48.0, 16.0), Vector3(0.0, 0.0, 10.0), true, true, false],   # enable hold
		[Vector2(112.0, 80.0), Vector3(10.0, 0.0, 10.0), true, true, false],
		[Vector2(176.0, 144.0), Vector3(10.0, 0.0, 10.0), true, true, false],
		[Vector2(112.0, 80.0), Vector3(-10.0, 0.0, -10.0), true, true, false], # re-enter held chunk
		[Vector2(112.0, 80.0), Vector3(-10.0, 0.0, -10.0), true, false, false], # disable hold
		[Vector2(1200.0, -900.0), Vector3(0.0, 0.0, -10.0), true, false, false], # jump > radius
		[Vector2(1200.0, -900.0), Vector3(0.0, 0.0, -10.0), true, false, true],
	]
	var sub_parity := true
	var rows_parity := true
	var wl_lazy := WorldMirror.new()
	wl_lazy.name = "SubLazy"
	wl_lazy.view_radius = 6
	wl_lazy.hold_min_free = 0
	add_child(wl_lazy)
	var lazy_stayed := true
	for i in steps.size():
		var st: Array = steps[i]
		var focus: Vector2 = st[0]
		var look_dir: Vector3 = st[1]
		var mark_loaded: bool = st[2]
		var want_hold: bool = st[3]
		var force_resub: bool = st[4]
		cam.look_at_from_position(Vector3(focus.x, 24.0, focus.y + 16.0), Vector3(focus.x, 0.0, focus.y) + look_dir)
		if mark_loaded:
			for c in wi.chunks:
				(wi.chunks[c] as ChunkView).loaded = true
			for c in wl.chunks:
				(wl.chunks[c] as ChunkView).loaded = true
			for c in wl_lazy.chunks:
				(wl_lazy.chunks[c] as ChunkView).loaded = true
		wi.set_hold(want_hold)
		wl.set_hold(want_hold)
		wl_lazy.set_hold(want_hold)
		wi.set_focus(focus)
		wl.set_focus(focus)
		wl_lazy.set_focus(focus)
		if force_resub:
			wi._sub_timer = WorldMirror.SUBSCRIBE_REFRESH
			wl._sub_timer = WorldMirror.SUBSCRIBE_REFRESH
			wl_lazy._sub_timer = WorldMirror.SUBSCRIBE_REFRESH
		WorldMirror.sub_incremental = true
		wi._update_subscription(0.2)
		wl_lazy._update_subscription(0.2)
		WorldMirror.sub_incremental = false
		wl._update_subscription(0.2)

		if not wl_lazy._wanted_lazy or not wl_lazy._subscribed_lazy:
			lazy_stayed = false
		var rows_inc := WorldMirror.square_rows_from_rows(wi._sq_center, wi._sq_radius, wi._sub_rows)
		var rows_leg := WorldMirror.square_rows(wl._sq_center, wl._sq_radius, wl._subscribed)
		if rows_inc != rows_leg:
			rows_parity = false
		var ai: Array = wi._asked.keys()
		var al: Array = wl._asked.keys()
		ai.sort()
		al.sort()
		var ci: Array = wi.chunks.keys()
		var cl: Array = wl.chunks.keys()
		ci.sort()
		cl.sort()
		var wmi: Array = wi._warm.keys()
		var wml: Array = wl._warm.keys()
		wmi.sort()
		wml.sort()
		var hi: Array = wi._held.keys()
		var hl: Array = wl._held.keys()
		hi.sort()
		hl.sort()
		if ai != al or ci != cl or wmi != wml or hi != hl or wi._subscribed != wl._subscribed:
			sub_parity = false
			break
	wl_lazy.queue_free()
	var prio_ok := WorldMirror._compute_prio_order(8, 2) == WorldMirror.prio_order(8, 2)
	wi._maybe_warm_prio(10)
	for _w in 200:
		if wi._prio_warm_task < 0:
			break
		OS.delay_msec(1)
		wi._poll_prio_warm()
	prio_ok = prio_ok and wi._prio_warm_task < 0 and WorldMirror._prio_orders.has(10 * WorldMirror.SECTORS + 2)
	check(sub_parity and rows_parity and lazy_stayed and prio_ok,
		"sub_incremental & prio_warm: parity %s, row-runs %s, lazy %s, async prio %s" % [
			str(sub_parity), str(rows_parity), str(lazy_stayed), str(prio_ok)])

	# 2. pack_multimesh_buffer + Anim.place_into_buffer + ContactShade.prepare parity
	var probe_cv := ChunkView.new()
	probe_cv.coord = Vector2i.ZERO
	add_child(probe_cv)
	var xforms: Array = []
	var colors: Array = []
	for i in 60:
		var ang := float(i) * 0.17
		xforms.append(Transform3D(Basis(Vector3.UP, ang).scaled(Vector3(1.1, 1.0, 0.9)), Vector3(float(i % 10), 0.2, float(i / 10))))
		colors.append(Color(0.2 + 0.01 * i, 0.5, 0.8, 1.0))
	var test_mesh := BoxMesh.new()
	var mm_ref := MultiMesh.new()
	mm_ref.transform_format = MultiMesh.TRANSFORM_3D
	probe_cv._fill(mm_ref, test_mesh, xforms, colors, true)
	var mm_buf := MultiMesh.new()
	var packed := ChunkView.pack_multimesh_buffer(xforms, colors, true, false)
	probe_cv._fill_buffer(mm_buf, test_mesh, xforms.size(), true, true, packed)
	var buf_match := mm_ref.instance_count == mm_buf.instance_count and packed.size() == 60 * 20
	if buf_match:
		for i in 60:
			if not mm_ref.get_instance_transform(i).is_equal_approx(mm_buf.get_instance_transform(i)) \
					or not mm_ref.get_instance_color(i).is_equal_approx(mm_buf.get_instance_color(i)):
				buf_match = false
				break

	var CS := preload("res://scripts/world/contact_shade.gd")
	var grp_ref := AnimScript.Group.new()
	var grp_buf := AnimScript.Group.new()
	var mm_anim_ref := MultiMesh.new()
	mm_anim_ref.transform_format = MultiMesh.TRANSFORM_3D
	var mm_anim_buf := MultiMesh.new()
	var empty_colors: Array = []
	probe_cv._fill(mm_anim_ref, test_mesh, xforms, empty_colors, true)
	for g: AnimScript.Group in [grp_ref, grp_buf]:
		for i in 60:
			g.keys.append(1000 + i)
			g.units.append(2000 + i)
			g.bases.append(xforms[i])
			g.stateful.append(1)
			g.customs.append(Color(0.1, 0.2, 0.0, 1.0))
	grp_ref.mm = mm_anim_ref
	var working := {}
	for i in 60:
		if i % 2 == 0:
			working[2000 + i] = 1
	AnimScript.place(grp_ref, null, working)
	var apack := ChunkView.pack_multimesh_buffer(xforms, empty_colors, true, false)
	var filled := AnimScript.place_into_buffer(grp_buf, null, working, apack, 16, 12)
	probe_cv._fill_buffer(mm_anim_buf, test_mesh, xforms.size(), false, true, filled)
	var anim_buf_match := mm_anim_ref.instance_count == mm_anim_buf.instance_count and filled.size() == 60 * 16
	if anim_buf_match:
		for i in 60:
			if not mm_anim_ref.get_instance_transform(i).is_equal_approx(mm_anim_buf.get_instance_transform(i)) \
					or not mm_anim_ref.get_instance_custom_data(i).is_equal_approx(mm_anim_buf.get_instance_custom_data(i)):
				anim_buf_match = false
				break

	var rings: Array = []
	for i in 12:
		CS.collect(rings, "stone-furnace", "furnace", test_mesh, xforms[i], Vector2(-1.0, -1.0), Vector2(1.0, 1.0), Vector2(2.0, 2.0))
	var cs_p1 := Node3D.new()
	var cs_p2 := Node3D.new()
	add_child(cs_p1)
	add_child(cs_p2)
	var cs_ref := CS.apply(cs_p1, null, rings)
	var cs_prep := CS.prepare(rings, CS.patch_ring_reach())
	var cs_opt := CS.apply_prepared(cs_p2, null, cs_prep)
	var cs_match := (cs_ref == null) == (cs_opt == null)
	if cs_match and cs_ref != null:
		cs_match = cs_ref.multimesh.instance_count == cs_opt.multimesh.instance_count \
			and cs_ref.custom_aabb.is_equal_approx(cs_opt.custom_aabb) \
			and not (cs_prep.box_buf.is_empty() and cs_prep.mask_buf.is_empty())
		if cs_match:
			for i in cs_ref.multimesh.instance_count:
				if not cs_ref.multimesh.get_instance_transform(i).is_equal_approx(cs_opt.multimesh.get_instance_transform(i)) \
						or not cs_ref.multimesh.get_instance_color(i).is_equal_approx(cs_opt.multimesh.get_instance_color(i)) \
						or not cs_ref.multimesh.get_instance_custom_data(i).is_equal_approx(cs_opt.multimesh.get_instance_custom_data(i)):
					cs_match = false
					break
	check(buf_match and anim_buf_match and cs_match,
		"MM buffer prep parity: static %s, Anim.place_into_buffer %s, ContactShade.prepare %s" % [
			str(buf_match), str(anim_buf_match), str(cs_match)])

	# 3. ChunkPrepJob worker build + Rec cache + stale unload cancellation
	var PW := preload("res://scripts/world/pipeline_warm.gd")
	var protos := ProtoDB.new()
	protos.add_entities([
		[1, "zz-test-box", "container", -0.4, -0.4, 0.4, 0.4, 200, 180, 0, 1, 1],
		[2, "zz-test-pipe", "pipe", -0.4, -0.4, 0.4, 0.4, 120, 120, 200, 1, 1],
	])
	ChunkView.chunk_mm_worker = true
	ChunkView.build_rec_cache = true
	var pw := WorldMirror.new()
	pw.protos = protos
	add_child(pw)
	var bcv := ChunkView.new()
	bcv.coord = Vector2i.ZERO
	bcv.loaded = true
	pw.chunks[Vector2i.ZERO] = bcv
	pw.add_child(bcv)
	for j in 64:
		pw._add([500 + j, 1, (j % 8) * 256 + 128, (j / 8) * 256 + 128, 0])
	await get_tree().process_frame
	pw._rebuild_dirty()
	var queued_worker := pw._prep_jobs.has(Vector2i.ZERO)
	for _f in 300:
		queued_worker = queued_worker or pw._prep_jobs.has(Vector2i.ZERO)
		if pw._prep_jobs.is_empty() and pw._dirty.is_empty() and pw._partial.is_empty():
			break
		OS.delay_msec(1)
		pw._rebuild_dirty()
	var box_mmi: MultiMeshInstance3D = bcv._nodes.get("box")
	var worker_built := queued_worker and pw._prep_jobs.is_empty() and box_mmi != null and box_mmi.multimesh.instance_count == 64

	# Rec cache hit on collect_entities + invalidation on connect/pack
	var ccv := ChunkView.new()
	ccv.coord = Vector2i(1, 0)
	ccv.loaded = true
	pw.chunks[Vector2i(1, 0)] = ccv
	pw.add_child(ccv)
	pw._add([9001, 2, 32 * 256 + 128, 128, 0])
	pw._add([9002, 2, 33 * 256 + 128, 128, 0])
	pw._flush_joins()
	var pipe_rec: WorldMirror.Rec = pw.entities[9001]
	pipe_rec.cache_gen = ModelLibrary.generation
	pipe_rec.cache_mesh = test_mesh
	pipe_rec.cache_parts = []
	pipe_rec.cache_xform = Transform3D(Basis.IDENTITY, Vector3(32.5, 0.0, 0.5))
	PW._seen_mesh[test_mesh] = true
	ccv.collect_entities(protos, pw.working, 0)
	var cache_hit_ok := ccv._prep_pending != null and ccv._prep_pending.wanted.has(test_mesh)
	PW._seen_mesh.erase(test_mesh)
	ccv._prep_pending = null
	pw.set_building_pack(9001, "")
	var pack_inval := pipe_rec.cache_gen == -1
	pipe_rec.cache_gen = ModelLibrary.generation
	pw._add([9003, 2, 32 * 256 + 128, 256 + 128, 0])
	pw._flush_joins()
	var pipe_inval := pipe_rec.cache_gen == -1

	# Stale unload cancellation while _prep_jobs in flight
	var ucv := ChunkView.new()
	ucv.coord = Vector2i(2, 0)
	ucv.loaded = true
	pw.chunks[Vector2i(2, 0)] = ucv
	pw.add_child(ucv)
	for j in 64:
		pw._add([8000 + j, 1, 64 * 256 + (j % 8) * 256 + 128, (j / 8) * 256 + 128, 0])
	# A build off the worker pool is what is cancelled here: taken as a live edit (--fast-edit-rebuild, the adds
	# counted live when a live message's marking is on) a chunk under 512 instances is built on the main thread.
	pw._dirty_live.erase(Vector2i(2, 0))
	pw._live_prep.erase(Vector2i(2, 0))
	# (A frame of its own, as the first build above: the frame's build budget may be spent by now.)
	await get_tree().process_frame
	pw._rebuild_dirty()
	if not pw._prep_jobs.has(Vector2i(2, 0)):
		print("ChunkPrepJob cancel: not on a worker: dirty %s, partial %s, jobs %s, building %s" % [pw._dirty.keys(), pw._partial, pw._prep_jobs.keys(), ucv.building])
	var cancelled_ok := pw._prep_jobs.has(Vector2i(2, 0))
	if cancelled_ok:
		pw._unload(Vector2i(2, 0))
	pw.flush_prep_jobs()
	pw._rebuild_dirty()
	cancelled_ok = cancelled_ok and pw._prep_jobs.is_empty() and pw._abandoned_prep_tasks.is_empty() and not pw.chunks.has(Vector2i(2, 0))
	check(worker_built and cache_hit_ok and pack_inval and pipe_inval and cancelled_ok,
		"ChunkPrepJob & Rec cache: worker %s, cache hit %s, pack/pipe inval %s/%s, cancel %s" % [
			str(worker_built), str(cache_hit_ok), str(pack_inval), str(pipe_inval), str(cancelled_ok)])

	pw.queue_free()
	cs_p1.queue_free()
	cs_p2.queue_free()
	probe_cv.queue_free()
	wi.queue_free()
	wl.queue_free()
	cam.queue_free()
	if prev_cam != null and is_instance_valid(prev_cam):
		prev_cam.current = true
	await get_tree().process_frame
	WorldMirror.sub_incremental = was_sub_inc
	Bridge.square_subs = was_sq
	ChunkView.build_rec_cache = was_rec_cache
	ChunkView.chunk_mm_worker = was_mm_worker


func _track3_gpu_opts() -> void:
	var AZ := preload("res://scripts/world/ao_zoom.gd")
	var GH := preload("res://scripts/world/ghosts.gd")
	var was_grass_cap := DecorativeLayer.grass_cap_lines
	var was_lantern := Avatar.lantern_dual_paraboloid
	var was_ssil_fade := AZ.ssil_zoom_fade
	var was_ghost_lod := GH.ghost_lod
	var was_warm_rings := WorldMirror.warm_rings
	var was_tree_dec := ModelLods.tree_shadow_decimate
	var was_far_coarse := FarChunks.far_coarse
	var was_far_rows := FarChunks.decide_row_runs
	var was_far_screen := FarChunks.screen_size
	var was_vcull := BeltLanesScript.belt_lane_vcull
	var was_focus_uni := LooksScript.grade_focus_uniform
	var was_fast_clouds := LooksScript.fast_night_clouds
	var prev_cam := get_viewport().get_camera_3d()

	# 1. 4K 3D grass line cap
	var sv4k := SubViewport.new()
	sv4k.size = Vector2i(3840, 2160)
	sv4k.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(sv4k)
	var svcam := Camera3D.new()
	svcam.projection = Camera3D.PROJECTION_ORTHOGONAL
	svcam.size = 90.0  # 2160 / 90 = 24 px/tile vs capped <= 1440 / 90 = 16 px/tile
	sv4k.add_child(svcam)
	svcam.current = true
	var svdeco := DecorativeLayer.new()
	sv4k.add_child(svdeco)
	DecorativeLayer.grass_cap_lines = true
	var z4k_cap: float = svdeco._grass_zoom(Vector2.ZERO)
	DecorativeLayer.grass_cap_lines = false
	var z4k_raw: float = svdeco._grass_zoom(Vector2.ZERO)
	check(ModelLods.counted_lines(2160.0) < 2160.0 and z4k_cap < z4k_raw,
		"3D grass 4K line cap: capped zoom %.3f < raw %.3f" % [z4k_cap, z4k_raw])

	# 2. Lantern dual-paraboloid vs cube shadow mode
	Avatar.lantern_dual_paraboloid = true
	var av_dp := Avatar.new()
	add_child(av_dp)
	var mode_dp: int = av_dp._lantern.omni_shadow_mode
	Avatar.lantern_dual_paraboloid = false
	var av_cb := Avatar.new()
	add_child(av_cb)
	var mode_cb: int = av_cb._lantern.omni_shadow_mode
	check(mode_dp == OmniLight3D.SHADOW_DUAL_PARABOLOID and mode_cb == OmniLight3D.SHADOW_CUBE,
		"lantern shadow mode: dual-paraboloid %d, cube fallback %d" % [mode_dp, mode_cb])

	# 3. SSIL zoom fade + 2-pass blur settings
	var az := AZ.new()
	var az_env := Environment.new()
	az_env.ssao_enabled = true
	az_env.ssil_enabled = true
	Settings.apply_ssao(az_env, true)
	az.env = az_env
	sv4k.add_child(az)
	svcam.size = 40.0  # close zoom: tiles_per_pixel < SSAO_FULL
	AZ.ssil_zoom_fade = true
	az._process(1.0)
	var ssil_near := az.ssil_on
	svcam.size = 200.0  # far zoom: tiles_per_pixel > SSAO_GONE
	az._process(1.0)
	var ssil_far_off := not az.ssil_on and not az.ssao_on
	AZ.ssil_zoom_fade = false
	az._process(1.0)
	var ssil_far_kept := az.ssil_on
	check(ssil_near and ssil_far_off and ssil_far_kept,
		"SSIL zoom fade: near %s, far off %s, rollback kept %s" % [str(ssil_near), str(ssil_far_off), str(ssil_far_kept)])

	# 4. Ghost LOD lod_bias
	var gparent := Node3D.new()
	add_child(gparent)
	var gm := BoxMesh.new()
	GH.ghost_lod = true
	GH._add(gparent, gm, [Transform3D.IDENTITY], null)
	GH.ghost_lod = false
	GH._add(gparent, gm, [Transform3D.IDENTITY], null)
	var gb_on := (gparent.get_child(0) as MultiMeshInstance3D).lod_bias
	var gb_off := (gparent.get_child(1) as MultiMeshInstance3D).lod_bias
	check(is_equal_approx(gb_on, 1.0) and is_equal_approx(gb_off, 8.0),
		"ghost LOD bias: enabled %.1f, disabled %.1f" % [gb_on, gb_off])

	# 5. WorldMirror.warm_rings
	var wm := WorldMirror.new()
	wm.view_radius = 6
	wm._sq_radius = 6
	WorldMirror.warm_rings = 0
	var lim_zero := wm._warm_limit()
	var reach_zero := wm.loaded_reach()
	WorldMirror.warm_rings = 6
	var lim_six := wm._warm_limit()
	var reach_six := wm.loaded_reach()
	check(lim_zero == 0 and reach_zero == 7 and lim_six > 0 and reach_six == 13,
		"warm_rings config: rings=0 -> lim %d reach %d; rings=6 -> lim %d reach %d" % [
			lim_zero, reach_zero, lim_six, reach_six])

	# 6. Tree shadow card decimation (16 leaf cards + 2 core triangles)
	var cv := PackedVector3Array()
	var cuv := PackedVector2Array()
	var cidx := PackedInt32Array()
	for c_i in 16:
		var ox := float(c_i) * 0.4
		var b := cv.size()
		cv.append_array([
			Vector3(ox - 0.3, 1.0, 0.0), Vector3(ox + 0.3, 1.0, 0.0),
			Vector3(ox + 0.3, 1.6, 0.0), Vector3(ox - 0.3, 1.6, 0.0),
		])
		cuv.append_array([Vector2(0.1, 0.0), Vector2(0.9, 0.0), Vector2(0.9, 1.0), Vector2(0.1, 1.0)])
		cidx.append_array([b, b + 1, b + 2, b, b + 2, b + 3])
	for _core in 2:
		var b := cv.size()
		cv.append_array([Vector3(-0.2, 0.5, 0.0), Vector3(0.2, 0.5, 0.0), Vector3(0.0, 1.2, 0.0)])
		cuv.append_array([Vector2(-1.0, 0.0), Vector2(-1.0, 0.0), Vector2(-1.0, 0.0)])
		cidx.append_array([b, b + 1, b + 2])
	var crown_arrs := []
	crown_arrs.resize(Mesh.ARRAY_MAX)
	crown_arrs[Mesh.ARRAY_VERTEX] = cv
	crown_arrs[Mesh.ARRAY_TEX_UV] = cuv
	crown_arrs[Mesh.ARRAY_INDEX] = cidx
	# Counted with --tree-shadow-shape=old's card quads (two triangles a card); the rounded shadows' polygons (the
	# default, 6 or 7 sides a card) after it.
	var quads_was: bool = ModelLods.Job.quad_shadows
	var counts := {}
	for quads: bool in [true, false]:
		ModelLods.Job.quad_shadows = quads
		ModelLods.tree_shadow_decimate = false
		var out_v_full := PackedVector3Array()
		var out_uv_full := PackedVector2Array()
		ModelLods.Job.crown_arrays(crown_arrs, false, out_v_full, out_uv_full)
		ModelLods.tree_shadow_decimate = true
		var out_v_dec := PackedVector3Array()
		var out_uv_dec := PackedVector2Array()
		ModelLods.Job.crown_arrays(crown_arrs, false, out_v_dec, out_uv_dec)
		counts[quads] = [out_v_full.size(), out_v_dec.size()]
	ModelLods.Job.quad_shadows = quads_was
	check(counts[true] == [102, 54],
		"tree shadow decimate (--tree-shadow-shape=old): full %d verts (34 tris), decimated %d verts (18 tris = 50%% cards + 100%% core)" % counts[true])
	# Rounded: 16 cards of 4-5 triangles and the 2 core ones; decimated, every other card of them and the core.
	var round_full: int = counts[false][0]
	var round_dec: int = counts[false][1]
	check(round_full >= (16 * 4 + 2) * 3 and round_full <= (16 * 5 + 2) * 3 and round_dec >= (8 * 4 + 2) * 3 and round_dec <= (8 * 5 + 2) * 3,
		"tree shadow decimate (rounded shadows): full %d verts, decimated %d verts (half the cards, every core triangle)" % [round_full, round_dec])

	# 7. FarChunks 2nd coarse HLOD tier & annulus parity
	var sphere := SphereMesh.new()
	sphere.radius = 2.0
	sphere.height = 4.0
	sphere.radial_segments = 24
	sphere.rings = 12
	var s_arrs := sphere.get_mesh_arrays()
	var sbake := FarChunks.Bake.new()
	sbake.surfaces = [[s_arrs[Mesh.ARRAY_VERTEX], s_arrs[Mesh.ARRAY_NORMAL], null, null, s_arrs[Mesh.ARRAY_INDEX], [FarChunks._surface_params(StandardMaterial3D.new())], null]]
	sbake.run()
	var m_fine := FarChunks.Merge.new()
	m_fine.coarse = false
	m_fine.groups = [[sbake, [Transform3D.IDENTITY], sphere, false]]
	m_fine.material = FarChunks.material()
	m_fine.nature_material = FarChunks.nature_material()
	m_fine.crown_material = FarChunks.crown_material()
	m_fine.run()
	var m_coarse := FarChunks.Merge.new()
	m_coarse.coarse = true
	m_coarse.groups = [[sbake, [Transform3D.IDENTITY], sphere, false]]
	m_coarse.material = FarChunks.material()
	m_coarse.nature_material = FarChunks.nature_material()
	m_coarse.crown_material = FarChunks.crown_material()
	m_coarse.run()
	var coarse_bake_ok := sbake.coarse_indices.size() > 0 and sbake.coarse_indices.size() < sbake.indices.size() and m_coarse.triangles < m_fine.triangles

	FarChunks.screen_size = false
	FarChunks.far_coarse = true
	var fc_worlds := {}
	for dr in [true, false]:
		var fw := WorldMirror.new()
		add_child(fw)
		fw.far_chunks.world = fw
		for cy in range(-1, 2):
			for cx in range(0, 17):
				var cc := Vector2i(cx, cy)
				var fcv := ChunkView.new()
				fcv.coord = cc
				fcv.loaded = true
				fw.chunks[cc] = fcv
				fw._row_add(cc, fcv)
				fw.add_child(fcv)
		fc_worlds[dr] = fw
	var tcam := Camera3D.new()
	add_child(tcam)
	tcam.current = true
	var coarse_parity := true
	var saw_coarse := false
	for cam_x in [16.0, 80.0, 200.0, 96.0]:
		tcam.global_position = Vector3(cam_x, 30.0, 16.0)
		var fpos := Vector2(cam_x, 16.0)
		for dr in [true, false]:
			FarChunks.decide_row_runs = bool(dr)
			var fw: WorldMirror = fc_worlds[dr]
			fw.set_focus(fpos)
			var fc: FarChunks = fw.far_chunks
			fc._check_timer = FarChunks.CHECK_INTERVAL
			fc._decide(1.0)
			while fc._pass_next < fc._pass_todo.size():
				fc._decide_slice()
		var fw_t: WorldMirror = fc_worlds[true]
		var fw_f: WorldMirror = fc_worlds[false]
		for c in fw_t.chunks:
			var st: FarChunks.State = (fw_t.chunks[c] as ChunkView).far
			var sf: FarChunks.State = (fw_f.chunks[c] as ChunkView).far
			if st.far != sf.far or st.coarse != sf.coarse:
				coarse_parity = false
				break
			if st.coarse:
				saw_coarse = true
	check(coarse_bake_ok and coarse_parity and saw_coarse,
		"far coarse HLOD: bake tris %d -> %d, decide_row_runs coarse parity %s (saw coarse %s)" % [
			m_fine.triangles, m_coarse.triangles, str(coarse_parity), str(saw_coarse)])

	# 8. Belt-lane vcull uniform + shader load
	var bl := BeltLanesScript.new()
	add_child(bl)
	var bm_icon := bl._material(1)
	var bm_model := bl._model_material(1)
	var vc_on := bool(bm_icon.get_shader_parameter("vcull")) and bool(bm_model.get_shader_parameter("vcull"))
	BeltLanesScript.belt_lane_vcull = false
	bl._set_params()
	var vc_off := (not bool(bm_icon.get_shader_parameter("vcull"))) and (not bool(bm_model.get_shader_parameter("vcull")))
	var icon_code := (load("res://shaders/belt_lane_icon.gdshader") as Shader).code
	var model_code := (load("res://shaders/belt_lane_model.gdshader") as Shader).code
	check(vc_on and vc_off and icon_code.contains("uniform bool vcull") and not model_code.is_empty(),
		"belt_lane_vcull: on=%s off=%s shaders loaded" % [str(vc_on), str(vc_off)])

	# 9. Grade focus uniform + cinematic_grade.gdshader text
	var lk := LooksScript.new()
	add_child(lk)
	var lcam := Camera3D.new()
	add_child(lcam)
	lcam.current = true
	lcam.look_at_from_position(Vector3(0.0, 30.0, 30.0), Vector3.ZERO)
	LooksScript.grade_focus_uniform = true
	var fd_on: float = lk._focus_distance()
	LooksScript.grade_focus_uniform = false
	var fd_off: float = lk._focus_distance()
	var cg_path := ProjectSettings.globalize_path("res://").path_join("../addons-src/cinematic-shaders/shaders/cinematic_grade.gdshader")
	var cg_text := FileAccess.get_file_as_string(cg_path)
	var cg_ok := cg_text.contains("look_focus_dist") and cg_text.contains("fast_night_clouds")
	check(fd_on > 30.0 and fd_on <= 600.0 and is_zero_approx(fd_off) and cg_ok,
		"looks focus uniform & night clouds: focus=%.1f, off=%.1f, shader updated=%s" % [fd_on, fd_off, str(cg_ok)])

	tcam.queue_free()
	lcam.queue_free()
	lk.queue_free()
	bl.queue_free()
	for fw in fc_worlds.values():
		(fw as WorldMirror).queue_free()
	wm.queue_free()
	gparent.queue_free()
	av_dp.queue_free()
	av_cb.queue_free()
	sv4k.queue_free()
	if prev_cam != null and is_instance_valid(prev_cam):
		prev_cam.current = true
	await get_tree().process_frame
	DecorativeLayer.grass_cap_lines = was_grass_cap
	Avatar.lantern_dual_paraboloid = was_lantern
	AZ.ssil_zoom_fade = was_ssil_fade
	GH.ghost_lod = was_ghost_lod
	WorldMirror.warm_rings = was_warm_rings
	ModelLods.tree_shadow_decimate = was_tree_dec
	FarChunks.far_coarse = was_far_coarse
	FarChunks.decide_row_runs = was_far_rows
	FarChunks.screen_size = was_far_screen
	BeltLanesScript.belt_lane_vcull = was_vcull
	LooksScript.grade_focus_uniform = was_focus_uni
	LooksScript.fast_night_clouds = was_fast_clouds


## (turn_id) An item keeps one turn where a lattice lane meets one drawn from the simulation: the simulation numbers each
## item along its run (one behind the item ahead), a simulated item turns by its number and a lattice lane is seeded from
## its front item's, so every item drawn, by a slot or by the simulation, turns as lattice_turn(its number); with
## --belt-draw-turn-id=old the simulated items turned by their unique ids (5159 changes on the loose-fed replay). Eight
## packed belts going into a ninth read with a gap (drawn from the simulation), as _belt_lattice_open's; both twins. And
## BeltSim.leads_on: a lane leading nowhere loaded (the square's edge) doesn't open its lattice exit (edge_shut).


func _belt_turn_id() -> void:
	BeltItemsScript.Job.view_cull = false
	var was_gd: bool = BeltItemsScript.State.force_gd
	var kept_native: bool = BeltItemsScript.State.lattice_native
	var twins := [[true, false]]
	if ClassDB.class_exists("BeltSimNative") and ClassDB.class_exists("BeltLatticeNative"):
		twins.append([false, true])
	for tw: Array in twins:
		var twin := "C++" if tw[1] else "GDScript"
		for on in [true, false]:
			BeltItemsScript.State.force_gd = tw[0]
			BeltItemsScript.State.lattice_native = tw[1]
			BeltLatticeScript.turn_id = on
			var items = BeltItemsScript.new()
			add_child(items)
			items._sync = true
			var uvr: Rect2 = items._view_rect()
			var ox := floorf(uvr.get_center().x) - 6.0 if uvr.size.x > 0.0 else 0.0
			var oy := floorf(uvr.get_center().y) + 0.5 if uvr.size.x > 0.0 else 30.0
			var lm: Array = []
			var sl: Array = []
			var id := 100
			var keys := PackedInt64Array()
			for u in range(1, 12):
				lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, ox + u + 1.0, oy, ox + u, oy, INF, INF,
					(u + 1) * 8 + 1 if u < 11 else 0))
				var at: Array = [32, 96, 160, 224] if u < 9 else [96, 224] if u == 9 else []
				sl.append_array([u * 8 + 1, 3000, at.size()])
				for q in at:
					sl.append_array([id, 1, q, 1])
					id += 1
				keys.append(u * 8 + 1)
			_bs_feed(items, 3000, {"lm": lm, "sl": sl}, 1)
			for f in 24:
				_bs_feed(items, 3001 + f, {}, 1)
			var sim = items._state.sim
			var nums: PackedInt32Array = sim.lane_fronts(keys, 3)
			var cnt: PackedInt32Array = sim.lane_fronts(keys)
			# (Belt u goes on into belt u + 1: each lane's front item numbered the lane ahead's count on from its front's;
			# numbers wrap at BeltSim.NUMS.)
			var fronts: Array = []
			var total := 0
			var counted := true
			var head := -1
			for q in keys.size():
				if cnt[q * 3 + 2] <= 0:
					continue
				fronts.append([keys[q], nums[q * 3 + 2], cnt[q * 3 + 2]])
				total += cnt[q * 3 + 2]
				head = nums[q * 3 + 2]
				if q + 1 < keys.size() and cnt[q * 3 + 5] > 0:
					counted = counted and posmod(nums[q * 3 + 2] - nums[q * 3 + 5] - cnt[q * 3 + 5], BeltSimScript.NUMS) == 0
			counted = counted and fronts.size() >= 9 and total == 34
			if on:
				check(counted, "turn_id %s simulation: a run's items numbered one behind another, front to back (%s)" % [twin, fronts])
			# Every drawn item's turn (cosine) against lattice_turn(n) of the run's numbers, from its front item's (a few
			# ahead too: the front lane's slots for the items gone on past the run's end).
			var want := {}
			for n in range(-8, total + 8):
				want[snappedf(cos(ItemCardsScript.lattice_turn(posmod(head + n, BeltSimScript.NUMS), BeltLatticeScript.TURN_RUN)), 0.0001)] = true
			var lat_n := 0
			var lat_in := 0
			var lat_native: bool = not (items._state.lattice is BeltLatticeScript)
			var kinds: Array = items._state.lattice.kind_keys() if lat_native else items._state.lattice.kinds.keys()
			for kk in kinds:
				for e in items.drawn_lattice(kk):
					if e != null:
						lat_n += 1
						lat_in += 1 if want.has(snappedf(float(e[1]), 0.0001)) else 0
			var sim_n := 0
			var sim_in := 0
			for e in items.drawn(1):
				# (Those on belts 9 and 10, drawn from the simulation: the records under the lattice's lanes aren't drawn.)
				if e != null and (e[0] as Vector3).x > ox + 9.0:
					sim_n += 1
					sim_in += 1 if want.has(snappedf(float(e[1]), 0.0001)) else 0
			if on:
				check(lat_n >= 20 and sim_n >= 2 and lat_in == lat_n and sim_in == sim_n,
					"turn_id %s: every item drawn turns by its number along the run, the lattice's slots (%d of %d) and the simulation's items (%d of %d)" % [twin, lat_in, lat_n, sim_in, sim_n])
				check(sim.leads_on(8 * 8 + 1) and not sim.leads_on(11 * 8 + 1) and not sim.leads_on(99 * 8 + 1),
					"edge_shut %s simulation: a lane going on into the next leads on, one leading nowhere loaded (the square's edge) and one it doesn't know don't" % twin)
			else:
				check(sim_n >= 2 and sim_in < sim_n,
					"turn_id %s: with --belt-draw-turn-id=old the simulation's items turn by their unique ids, not as the lattice's slots (%d of %d alike)" % [twin, sim_in, sim_n])
			items.queue_free()
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.State.lattice_native = kept_native
	BeltLatticeScript.turn_id = true
	BeltItemsScript.Job.view_cull = true


## Items' model variants on belts (owner: "it should automatically choose variants when named like this"): a pack's
## items/stone-1..3 drawn on belts as all three, each item keeping its own (its number along its run, as its turn) across
## a re-read of its lane; a packed lane's slots each drawn by the kind of their item's variant (the shader's pick,
## belt_lattice_variant, as drawn_lattice reports who the slot's item is); far lanes' icons the same by their place;
## --model-variants=off: the first alone, as before. Both twins (GDScript, C++).


func _belt_item_variants() -> void:
	const ItemModels := preload("res://scripts/world/item_models.gd")
	var step := ItemCardsScript.VARIANT_STEP
	var coal := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(ItemModels.DIR + "coal.glb"))
	var dir := ProjectSettings.globalize_path("user://belt-variants")
	_remove_tree(dir)
	for i in [1, 2, 3]:
		DirAccess.make_dir_recursive_absolute(dir.path_join("Vars/items"))
		var f := FileAccess.open(dir.path_join("Vars/items/stone-%d.glb" % i), FileAccess.WRITE)
		f.store_buffer(coal)
		f.close()
	ModelPacksScript.configure(dir, ["dir:Vars", "builtin:placeholders"], [])
	ModelPacksScript.wait()
	var protos := ProtoDB.new()
	protos.item_names[1] = "stone"
	check(ItemModels.variant_count("stone") == 3, "belt variants: the pack's items/stone-1..3 are stone's 3 variants (%d)" % ItemModels.variant_count("stone"))
	BeltItemsScript.Job.view_cull = false
	var was_gd: bool = BeltItemsScript.State.force_gd
	var kept_native: bool = BeltItemsScript.State.lattice_native
	var twins := [[true, false]]
	if ClassDB.class_exists("BeltSimNative") and ClassDB.class_exists("BeltLatticeNative"):
		twins.append([false, true])
	for tw: Array in twins:
		var twin := "C++" if tw[1] else "GDScript"
		for variants_on in [true, false]:
			ItemModels.variants_on = variants_on
			BeltItemsScript.State.force_gd = tw[0]
			BeltItemsScript.State.lattice_native = tw[1]
			var items = BeltItemsScript.new()
			add_child(items)
			items._sync = true
			items.protos = protos
			var uvr: Rect2 = items._view_rect()
			var ox := floorf(uvr.get_center().x) - 10.0 if uvr.size.x > 0.0 else 0.0
			var oy := floorf(uvr.get_center().y) + 0.5 if uvr.size.x > 0.0 else 30.0
			# A run of 15 belts going east with 2 stones each (30, read with gaps: the simulation's), then a run of 8
			# full ones (4 each: a packed lane, the lattice's) further south.
			var lm: Array = []
			var sl: Array = []
			var uids: Array = []
			for u in range(1, 16):
				lm.append_array(_bs_lane(u * 8 + 1, 1, 256, 8, ox + u + 1.0, oy, ox + u, oy, INF, INF, (u + 1) * 8 + 1 if u < 15 else 0))
				sl.append_array([u * 8 + 1, 3000, 2])
				for q in [96, 224]:
					sl.append_array([100 + uids.size(), 1, q, 1])
					uids.append(100 + uids.size())
			for u in range(1, 9):
				lm.append_array(_bs_lane(400 + u * 8 + 1, 1, 256, 8, ox + u + 1.0, oy + 3.0, ox + u, oy + 3.0, INF, INF, 400 + (u + 1) * 8 + 1 if u < 8 else 0))
				sl.append_array([400 + u * 8 + 1, 3000, 4])
				for q in [32, 96, 160, 224]:
					sl.append_array([1000 + u * 4 + q / 64, 1, q, 1])
			_bs_feed(items, 3000, {"lm": lm, "sl": sl}, 1)
			for f in 12:
				_bs_feed(items, 3001 + f, {}, 1)
			var key_of := func(uid: int) -> int:
				if items._state.draw != null:
					return int(items._state.draw.key_of(uid))
				var it = items._state.items.get(uid)
				return 0 if it == null else int(it.key)
			var keys := {}
			var counts := {}
			for uid: int in uids:
				var k: int = key_of.call(uid)
				keys[uid] = k
				counts[k] = int(counts.get(k, 0)) + 1
			var drawn_kinds := 0
			for k in counts:
				drawn_kinds += 1 if items.drawn(k).any(func(e) -> bool: return e != null) else 0
			if variants_on:
				check(counts.size() == 3 and counts.has(1) and counts.has(1 + step) and counts.has(1 + 2 * step)
					and counts.values().all(func(n: int) -> bool: return n >= 5) and drawn_kinds == 3,
					"belt variants %s: a lane of 30 stones drawn as all three of its models, spread out, each kind drawn: %s" % [twin, counts])
			else:
				check(counts.keys() == [1], "belt variants %s: --model-variants=off, every stone its first model, as before: %s" % [twin, counts])
			# The lane read again (the game's places, the same items): each keeps its kind.
			var sl2: Array = []
			for u in range(1, 16):
				sl2.append_array([u * 8 + 1, 3013, 2])
				for q in [96, 224]:
					var j := (u - 1) * 2 + (0 if q == 96 else 1)
					sl2.append_array([uids[j], 1, q, 1])
			_bs_feed(items, 3013, {"sl": sl2}, 1)
			for f in 6:
				_bs_feed(items, 3014 + f, {}, 1)
			var same := 0
			for uid: int in uids:
				same += 1 if key_of.call(uid) == keys[uid] else 0
			check(same == uids.size(), "belt variants %s: after a re-read every item keeps its variant (%d of %d)" % [twin, same, uids.size()])
			# The packed lane: the lattice's kinds for each variant over the same records, each slot drawn by its item's.
			var lat_native: bool = not (items._state.lattice is BeltLatticeScript)
			var lkinds: Array = items._state.lattice.kind_keys() if lat_native else items._state.lattice.kinds.keys()
			var picks := {}
			var slots := 0
			for kk in lkinds:
				for e in items.drawn_lattice(kk):
					if e != null and int(e[2]) >= 0:
						slots += 1
						var v := ItemCardsScript.lattice_variant(int(e[2]), int(e[3]), 3 if variants_on else 0)
						picks[v] = int(picks.get(v, 0)) + 1
			var lat_mmis := {}
			for v in 3:
				var mmi: MultiMeshInstance3D = items._lat_cards._kinds.get(1 + v * step)
				if mmi != null:
					var got := []
					for name in ["belt_variant", "belt_variants", "belt_base"]:
						var value: Variant = mmi.get_instance_shader_parameter(name)
						got.append(0 if value == null else int(value))
					lat_mmis[v] = got
			if variants_on:
				check(slots >= 20 and picks.size() == 3 and lat_mmis.size() == 3 and lat_mmis[1][0] == 1 and lat_mmis[2][0] == 2
					and lat_mmis[0][1] == 3 and lat_mmis[1][2] == lat_mmis[0][2],
					"belt variants %s: a packed lane's %d slots are of all three variants %s, a kind each over the same records %s" % [twin, slots, picks, lat_mmis])
			else:
				check(slots >= 20 and lat_mmis.size() == 1, "belt variants %s: --model-variants=off, a packed lane is one kind, as before %s" % [twin, lat_mmis])
			items.queue_free()
	ItemModels.variants_on = true
	# Far lanes (belt_lanes.gd): each icon its place's variant, in its variant's kind; none lost.
	var l: Array = []
	var counts_far: Array = []
	for b in 20:
		l.append_array([(b * 2 + 1) * 128, 128, 4, 1, 1])
		counts_far.append_array([4, 4])
	var plain: Dictionary = BeltLanesScript.Job.build(l, counts_far, 0.2)
	var far: Dictionary = BeltLanesScript.Job.build(l, counts_far, 0.2, [], {1: 0.05}, {}, {1: 3})
	var far_n := {}
	for k in far:
		far_n[k] = (far[k] as PackedFloat32Array).size() / BeltLanesScript.STRIDE
	check(BeltLanesScript.Job.icon_count(plain) == 160 and BeltLanesScript.Job.icon_count(far) == 160 and far_n.size() == 3
		and far_n.has(1 + step) and far_n.has(1 + 2 * step),
		"belt variants: far lanes' 160 stones drawn as the three variants by their places: %s" % [far_n])
	BeltItemsScript.State.force_gd = was_gd
	BeltItemsScript.State.lattice_native = kept_native
	BeltItemsScript.Job.view_cull = true
	ModelPacksScript.configure("", [], [])
	_remove_tree(dir)


## The moving gap (owner: "they don't just move in unison"): a moving lattice has the map's phase, its line's items
## another; where the lane its items go on into is drawn from the simulation (read short of full), the game's item at
## its exit, its slot already wrapped to the entry (the lattice ahead), was hidden by the mask until it left: a gap
## standing at the join while the line moved. --belt-draw-lattice-open (the default): a moving lattice ahead of the
## simulation's items leaves its exit's cell unmarked there, one in step (or behind) keeps it; off, as before, marked.
## Eight packed belts going east moving into a ninth read with a gap, the items at four phases a quarter gap apart
## (so the lattice is ahead at some and not at others); both lattices, which agree.
## A pack's belt_lane_offset on the far lanes' icons (belt_lanes.gd; belt_lane_inset_test.gd has the near lanes): a belt each way, both lanes at the offset on either side; a curve's
## lanes about its corner at the middle radius +- the offset.


func _belt_lane_inset_far() -> void:
	for dir in [0, 4, 8, 12]:
		var at := Vector2(-5.5, 7.5)
		var built: Dictionary = BeltLanesScript.Job.build([roundi(at.x * 256), roundi(at.y * 256), dir, 1, 2], [1, 1], 0.2, [], null, {}, {}, 0.21)
		var sides := []
		for item in [1, 2]:
			var buf: PackedFloat32Array = built.get(item, PackedFloat32Array())
			check(buf.size() >= BeltLanesScript.STRIDE, "far lane item %d drawn (dir %d)" % [item, dir])
			if buf.size() < BeltLanesScript.STRIDE:
				continue
			var p := Vector2(buf[3], buf[11])
			var right: Vector2 = BeltLanesScript.RIGHTS[dir / 4]
			var off := (p - at).dot(right)
			check(absf(absf(off) - 0.21) < 0.002, "far lane item %d dir %d: %.3f from the middle" % [item, dir, off])
			sides.append(signf(off))
		check(sides.size() == 2 and sides[0] != sides[1], "far lanes on either side (dir %d): %s" % [dir, str(sides)])
		# The default, as before: Factorio's.
		var plain: Dictionary = BeltLanesScript.Job.build([roundi(at.x * 256), roundi(at.y * 256), dir, 1, 0], [1, 0], 0.2)
		var pb: PackedFloat32Array = plain.get(1, PackedFloat32Array())
		check(pb.size() >= BeltLanesScript.STRIDE and absf(absf((Vector2(pb[3], pb[11]) - at).dot(BeltLanesScript.RIGHTS[dir / 4])) - BeltLanesScript.LANE) < 0.002, "far lane default (dir %d)" % dir)
	for d in 4:
		for way in [-1, 1]:
			var t := (d + 3) % 4 if way > 0 else (d + 1) % 4
			var at2 := Vector2(2.5, -3.5)
			var corner: Vector2 = at2 - BeltLanesScript.AHEADS[t] * 0.5 + BeltLanesScript.AHEADS[d] * 0.5
			var radii := []
			for lane in 2:
				for f in [0.0, 0.5, 1.0]:
					var r := (BeltLanesScript.Job.curve_point(at2, d, way, lane, f, 0.21) - corner).length()
					check(absf(absf(r - 0.5) - 0.21) < 0.002, "far curve d %d way %d lane %d f %.1f radius %.3f" % [d, way, lane, f, r])
				radii.append(signf((BeltLanesScript.Job.curve_point(at2, d, way, lane, 0.5, 0.21) - corner).length() - 0.5))
			check(radii[0] != radii[1], "far curve lanes on either side of the middle radius (d %d way %d)" % [d, way])
