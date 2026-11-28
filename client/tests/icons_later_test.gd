extends SceneTree
## Kit.icon_into (the hover panel's icons read on a worker thread, so a camera sweeping new kinds under a
## still cursor never waits for a file): an icon not cached yet leaves the rect empty and starts one read,
## Kit.poll_icons() puts the same texture Kit.item_icon() gives once the read is done, a rect given another
## icon meanwhile keeps that one, a cached icon goes in at once, and --icons-later=off reads at once as
## before. With a Factorio install in reach (local runs) also a real icon and a tree's (an entity without an item, from the entity kind's icon); without one (CI) the
## colour swatches take the same path. Run headless:
##   godot --headless --path client -s res://tests/icons_later_test.gd
## Prints "ICONS LATER FAILS: 0" when all pass; quits with 1 otherwise.

const Kit := preload("res://scripts/ui/factorio/kit.gd")
const ItemIcons := preload("res://scripts/world/item_icons.gd")

var _fails := 0


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _wait_for(rect: TextureRect) -> bool:
	for i in 400:
		Kit.poll_icons()
		if rect.texture != null:
			return true
		await process_frame
	return false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	ItemIcons.factorio_data_dir()
	var names := ["no-such-item-xyz", "iron-plate", "tree-01"]
	for name in names:
		_check(not ItemIcons.any_ready(name), "%s not cached at the start" % name)
		var rect := TextureRect.new()
		root.add_child(rect)
		Kit.icon_into(rect, name)
		_check(rect.texture == null, "%s: no icon until the worker has read it" % name)
		_check(Kit._icon_jobs.has(name), "%s: one read started" % name)
		Kit.icon_into(rect, name)
		_check(Kit._icon_jobs.size() == 1, "%s: asked twice, still one read" % name)
		_check(await _wait_for(rect), "%s: the icon arrives" % name)
		_check(Kit._icon_jobs.is_empty() and Kit._icon_waiting.is_empty(), "%s: nothing left waiting" % name)
		_check(ItemIcons.any_ready(name), "%s: cached after the read" % name)
		_check(rect.texture == Kit.item_icon(name), "%s: the same texture item_icon gives" % name)
		var again := TextureRect.new()
		root.add_child(again)
		Kit.icon_into(again, name)
		_check(again.texture == rect.texture, "%s: cached, put in at once" % name)
		rect.queue_free()
		again.queue_free()
	if ItemIcons.data_dir != "":
		_check(Kit.item_icon("iron-plate") != Kit.item_icon("no-such-item-xyz"), "the install's iron plate, not a swatch")
	# A rect given another icon before the first read ended keeps the second.
	var reused := TextureRect.new()
	root.add_child(reused)
	Kit.icon_into(reused, "another-uncached-one")
	Kit.icon_into(reused, "iron-plate")  # cached above
	var first: Texture2D = reused.texture
	for i in 400:
		Kit.poll_icons()
		if Kit._icon_jobs.is_empty():
			break
		await process_frame
	Kit.poll_icons()
	_check(first != null and reused.texture == first, "a reused rect keeps its newer icon")
	# A read that ends after the graphics changed (ModGraphics.generation) is dropped and read again (perf-w4-fix B-S2).
	var stale := TextureRect.new()
	root.add_child(stale)
	Kit.icon_into(stale, "stale-uncached-one")
	var job0: Array = Kit._icon_jobs.get("stale-uncached-one", [])
	_check(job0.size() >= 4, "an icon job keeps the stamps it was read under")
	ItemIcons.ModGraphics.generation += 1
	if job0.size() >= 4:
		for i in 400:
			if WorkerThreadPool.is_task_completed(job0[0]):
				break
			await process_frame
		Kit.poll_icons()
		var job1: Array = Kit._icon_jobs.get("stale-uncached-one", [])
		_check(job1.size() >= 4 and job1[0] != job0[0] and int(job1[2]) == ItemIcons.ModGraphics.generation,
			"a read under older graphics dropped and started again")
		_check(stale.texture == null and not ItemIcons.any_ready("stale-uncached-one"), "the stale read not stored")
	_check(await _wait_for(stale), "the read again arrives")
	_check(Kit._icon_jobs.is_empty(), "nothing left reading after it")
	# --icons-later=off's path: read at once, as before.
	Kit.icons_later = false
	var now := TextureRect.new()
	root.add_child(now)
	Kit.icon_into(now, "yet-another-uncached-one")
	_check(now.texture != null and not Kit._icon_jobs.has("yet-another-uncached-one"), "--icons-later=off reads at once")
	Kit.icons_later = true
	print("ICONS LATER FAILS: %d" % _fails)
	quit(1 if _fails > 0 else 0)
