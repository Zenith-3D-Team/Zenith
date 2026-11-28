extends SceneTree
## Running spikes, part B (R&D run-spikes steps 4 and 6):
## - frame_budget.gd: a grant takes off the frame's other scripts' time already spent past their usual share
##   (--budget-spent=off: not), the floors and the reducing systems' raise staying; a slice's next item counted by
##   its typical cost (item_est, note_item, fits; --budget-predict=off: the clock alone).
## - item_models.gd: a pack's .glb item model read on a worker thread (ready() says no until it is in, then the
##   same mesh each time); mesh_for never waits for a read still running; --item-models-later=off reads at once.
## Run headless:
##   godot --headless --audio-driver Dummy --path client -s res://tests/spikes_b_test.gd
## Prints "SPIKES B FAILS: 0" when all pass; quits with 1 otherwise.

const FrameBudget := preload("res://scripts/world/frame_budget.gd")
const ItemModels := preload("res://scripts/world/item_models.gd")
const ModelPacks := preload("res://scripts/world/model_packs.gd")
const TestEnv := preload("res://tests/test_env.gd")

var _fails := 0


func _check(cond: bool, what: String) -> void:
	if not cond:
		_fails += 1
		print("FAIL: ", what)


func _initialize() -> void:
	TestEnv.isolate("spikes_b_test")
	_run.call_deferred()


func _run() -> void:
	_budget_spent()
	_budget_predict()
	await _item_models_later()
	print("SPIKES B FAILS: %d" % _fails)
	quit(1 if _fails > 0 else 0)


## A grant in a fresh frame, the frame's other scripts having spent `other` µs so far (-1: the clock's).
func _grant_after(system: StringName, other: int, aware := true) -> int:
	FrameBudget.reset()
	FrameBudget.test_no_deadline = true
	FrameBudget.test_other_usec = 3000
	FrameBudget.spent_aware = aware
	FrameBudget.test_spent_other_usec = other
	return FrameBudget.grant(system)


func _budget_spent() -> void:
	var aware_was := FrameBudget.spent_aware
	var no_dead_was := FrameBudget.test_no_deadline
	var base := _grant_after(&"build", 0)
	var ema := int(FrameBudget._other_ema)
	var late := _grant_after(&"build", ema + 2000)
	_check(base > 3000 and late == base - 2000,
		"build's grant less the other scripts' time past their share: %d -> %d" % [base, late])
	var within := _grant_after(&"build", maxi(ema - 1000, 0))
	_check(within == base, "other scripts within their share take nothing off: %d vs %d" % [within, base])
	var off := _grant_after(&"build", ema + 2000, false)
	_check(off == base, "--budget-spent=off: as before (%d vs %d)" % [off, base])
	var floored := _grant_after(&"build", ema + 20000)
	_check(floored == int(FrameBudget.SYSTEMS[&"build"][2]), "the floor stays however late the frame is: %d" % floored)
	FrameBudget.reset()
	FrameBudget.test_no_deadline = true
	FrameBudget.test_other_usec = 3000
	FrameBudget.test_spent_other_usec = 30000
	FrameBudget.waiting(&"lods", 5)
	var lods := FrameBudget.grant(&"lods")
	_check(not FrameBudget.reduce_floors or lods >= int(FrameBudget.REDUCERS[&"lods"]),
		"the reducing systems' raise stays (lods %d)" % lods)
	var hyd := _grant_after(&"hydrate", 0)
	_check(FrameBudget.SYSTEMS.has(&"hydrate") and hyd > 0 and hyd <= int(FrameBudget.SYSTEMS[&"hydrate"][1]),
		"the disk cache's replay has a slice of its own: %d" % hyd)
	FrameBudget.spent_aware = aware_was
	FrameBudget.test_no_deadline = no_dead_was
	FrameBudget.reset()


func _budget_predict() -> void:
	var was := FrameBudget.predict
	FrameBudget.predict = true
	FrameBudget.reset()
	_check(FrameBudget.item_est(&"wires") == 0, "no estimate before any item")
	FrameBudget.note_item(&"wires", 1000)
	_check(FrameBudget.item_est(&"wires") == 1000, "the first item sets it")
	FrameBudget.note_item(&"wires", 3000)
	_check(FrameBudget.item_est(&"wires") == 2000, "a slower one raises it halfway at once: %d" % FrameBudget.item_est(&"wires"))
	FrameBudget.note_item(&"wires", 0)
	_check(FrameBudget.item_est(&"wires") == 1800, "a faster one lowers it slowly: %d" % FrameBudget.item_est(&"wires"))
	FrameBudget.note_item(&"messages", 5000, "chunk")
	_check(FrameBudget.item_est(&"messages", "chunk") == 5000 and FrameBudget.item_est(&"messages", "bs") == 0,
		"kinds within a system are apart (a chunk message's cost isn't a belt message's)")
	var now := Time.get_ticks_usec()
	_check(FrameBudget.fits(now, 1500, 0, 99999), "the first item of a slice always runs")
	_check(not FrameBudget.fits(now, 1500, 1, 2000), "a second that wouldn't fit waits")
	_check(FrameBudget.fits(now, 1500000, 1, 2000), "a second that fits runs")
	FrameBudget.predict = false
	_check(FrameBudget.item_est(&"wires") == 0, "--budget-predict=off: no estimate, the clock alone")
	FrameBudget.note_item(&"lanes", 5000)
	FrameBudget.predict = true
	_check(FrameBudget.item_est(&"lanes") == 0, "--budget-predict=off: nothing noted")
	FrameBudget.predict = was
	FrameBudget.reset()


## A pack folder with a .glb item model (Placeholders' iron and copper plates, copied as files).
func _pack_dir() -> String:
	var pdir := ProjectSettings.globalize_path("user://spikes-b-packs")
	var items := pdir.path_join("ItemPack").path_join("items")
	DirAccess.make_dir_recursive_absolute(items)
	for name in ["iron-plate", "copper-plate", "iron-gear-wheel"]:
		var bytes := FileAccess.get_file_as_bytes("res://assets/models/packs/placeholders/items/%s.glb" % name)
		var f := FileAccess.open(items.path_join(name + ".glb"), FileAccess.WRITE)
		f.store_buffer(bytes)
		f.close()
	return pdir


func _wait_ready(item: String) -> bool:
	for i in 600:
		if ItemModels.ready(item):
			return true
		await process_frame
	return false


func _item_models_later() -> void:
	var later_was := ItemModels.later
	var pdir := _pack_dir()
	ModelPacks.configure(pdir, ["dir:ItemPack"], [])
	ModelPacks.wait()
	var path := ModelPacks.item_model_path("iron-plate")
	_check(path.begins_with(pdir), "the test pack draws the iron plate: %s" % path)
	ItemModels.later = true
	var reads := ItemModels.reads_later
	_check(not ItemModels.ready("iron-plate"), "a .glb not read yet: not ready, its read started")
	_check(ItemModels._jobs.has("iron-plate"), "one read on a worker")
	ItemModels.ready("iron-plate")
	# (A quick read may be in by the second ask: taken in then, counted once, no second read started.)
	_check(ItemModels._jobs.size() == 1 or (ItemModels._jobs.is_empty() and ItemModels.reads_later == reads + 1),
		"asked again: still one read (or that one read already in)")
	_check(await _wait_ready("iron-plate"), "the read ends and it is ready")
	var mesh := ItemModels.mesh_for("iron-plate")
	_check(mesh != null and mesh.get_surface_count() > 0, "its mesh from the worker's read")
	_check(ItemModels.reads_later == reads + 1 and ItemModels._jobs.is_empty(), "counted, nothing left waiting")
	_check(is_same(ItemModels.mesh_for("iron-plate"), mesh) and ItemModels.ready("iron-plate"), "cached: the same mesh after")
	var direct := ItemModels.read(path)
	_check(direct != null and direct.get_surface_count() == mesh.get_surface_count()
		and direct.get_aabb().is_equal_approx(mesh.get_aabb()), "the same model as a read on the main thread")
	# mesh_for while a read still runs: read here, not waited for; the worker's result dropped when it ends.
	_check(not ItemModels.ready("copper-plate"), "copper plate: its read started")
	var now_mesh := ItemModels.mesh_for("copper-plate")
	_check(now_mesh != null and not ItemModels._jobs.has("copper-plate"), "mesh_for during a read answers at once")
	_check(await _wait_ready("copper-plate") and is_same(ItemModels.mesh_for("copper-plate"), now_mesh),
		"the worker's read, once ended, doesn't replace the one in use")
	for i in 600:
		ItemModels.ready("copper-plate")
		if ItemModels._orphans.is_empty():
			break
		await process_frame
	_check(ItemModels._orphans.is_empty(), "an overtaken read's task is waited for once it ends")
	# --item-models-later=off: at once.
	ItemModels.later = false
	_check(ItemModels.ready("iron-gear-wheel") and ItemModels._jobs.is_empty(), "--item-models-later=off: read at once")
	_check(ItemModels.mesh_for("iron-gear-wheel") != null, "--item-models-later=off: its mesh there")
	# Zenith's own imported scenes stay on the main thread (ResourceLoader).
	_check(ItemModels._main_only("res://assets/models/packs/placeholders/items/iron-plate.glb", false),
		"an imported res:// scene is read on the main thread only")
	ItemModels.later = later_was
	ModelPacks.configure("", [], [])
	ModelPacks.wait()
