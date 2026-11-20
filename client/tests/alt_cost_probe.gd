## Alt-mode icon order's cost in a running client (testing agent's probe; not part of any suite): loads the
## main scene, turns Alt-mode on and, each frame, times alt_overlay.gd's collect with the order made again
## (as while walking: key cleared), kept (an unchanged view) and the old order, at several zooms.
## godot --headless --path client res://tests/alt_cost_probe.tscn -- --factorio-port=<mock> --port=<own> --alt-mode
extends Node

const AltOverlay := preload("res://scripts/ui/factorio/alt_overlay.gd")

var _t := 0.0
var _phase := -1
var _samples := {}
var _watch_last := []
var _watch_frames := 0
var _watch_changes := 0
var _watch_why := []
const PHASES := [["standing watch", 30.0, false], ["default zoom", 30.0, false], ["zoomed out 80", 80.0, false], ["zoomed out 140", 140.0, false],
	["Factorio's view 140", 140.0, true]]
const WARM := 25.0
const EACH := 6.0


func _ready() -> void:
	get_window().size = Vector2i(1920, 1080)
	add_child.call_deferred((load("res://scenes/main.tscn") as PackedScene).instantiate())


func _find(n: Node) -> Node:
	if n.get_script() == AltOverlay:
		return n
	for c in n.get_children():
		var f := _find(c)
		if f != null:
			return f
	return null


func _process(delta: float) -> void:
	_t += delta
	if _t < WARM:
		return
	var overlay = _find(self)
	if overlay == null:
		if _t > WARM + 30.0:
			print("alt cost probe: no Alt-mode overlay found")
			get_tree().quit(1)
		return
	overlay.on = true
	var rig = overlay.player.get("rig") if overlay.player != null else null
	if rig == null:
		return
	var phase := int((_t - WARM) / EACH)
	if phase >= PHASES.size():
		print("alt cost probe, standing: the overlay's layers made again in %d of %d frames (key parts changed: %s)" % [_watch_changes, _watch_frames, _watch_why])
		for k in _samples:
			var s: Array = _samples[k]
			var made := PackedFloat32Array()
			var kept := PackedFloat32Array()
			var old := PackedFloat32Array()
			var n := 0
			var layers := 0
			for r in s:
				made.append(r[0]); kept.append(r[1]); old.append(r[2]); n = r[3]; layers = r[4]
			made.sort(); kept.sort(); old.sort()
			var med := func(a: PackedFloat32Array) -> float: return a[a.size() / 2] if a.size() > 0 else -1.0
			var p95 := func(a: PackedFloat32Array) -> float: return a[int(a.size() * 0.95)] if a.size() > 0 else -1.0
			print("alt cost probe, %s: %d icons, %s; collect median / p95 ms: order made %.2f / %.2f, kept %.2f / %.2f, old %.2f / %.2f (%d frames)"
				% [k, n, "flat" if layers < 0 else "%d layers" % layers, med.call(made), p95.call(made), med.call(kept), p95.call(kept),
					med.call(old), p95.call(old), s.size()])
		get_tree().quit(0)
		return
	if phase != _phase:
		_phase = phase
		rig.distance = PHASES[phase][1]
		rig._distance_goal = PHASES[phase][1]
		rig.max_distance = maxf(rig.max_distance, PHASES[phase][1])
		rig.orthographic = PHASES[phase][2]
		return
	if _t - WARM - phase * EACH < 2.0:
		return  # the camera settling
	if phase == 0:
		# Only watch: did the overlay's own _draw keep last frame's layers (its key unchanged)?
		var now: Array = (overlay._layers_key as Array).duplicate()
		_watch_frames += 1
		if now != _watch_last:
			_watch_changes += 1
			if _watch_frames > 1 and _watch_why.size() < 3:
				var diff := []
				for i in mini(now.size(), _watch_last.size()):
					if now[i] != _watch_last[i]:
						diff.append(i)
				_watch_why.append(diff)
		_watch_last = now
		return
	AltOverlay.icon_order = true
	overlay._layers_key = []
	var t0 := Time.get_ticks_usec()
	overlay.collect()
	var made := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	overlay.collect()
	var kept := (Time.get_ticks_usec() - t0) / 1000.0
	var n: int = overlay._e_tex.size()
	var layers: int = -1 if overlay._flat else overlay._layers_used
	AltOverlay.icon_order = false
	t0 = Time.get_ticks_usec()
	overlay.collect()
	var old := (Time.get_ticks_usec() - t0) / 1000.0
	AltOverlay.icon_order = true
	var key: String = PHASES[phase][0]
	if not _samples.has(key):
		_samples[key] = []
	_samples[key].append([made, kept, old, n, layers])
	return
