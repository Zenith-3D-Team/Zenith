extends Node
## N9: the client's own pipeline rule (pipeline_marks.gd) on records read from a real game, for
## tools/live_check.py --only pipevis to compare with Factorio's fluid segments. Reads a JSON file
## {"protos": [protos records], "eprops": [eprops records], "records": [entity records]} and writes
## {"groups": {unit: pipeline number}} for every pipe, pipe to ground and storage tank. Run headless:
##   godot --headless --audio-driver Dummy --path client res://tests/pipeline_predict.tscn -- --in=<file> --out=<file>

const WorldMirror := preload("res://scripts/world/world.gd")
const ChunkView := preload("res://scripts/world/chunk_view.gd")
const PipelineMarks := preload("res://scripts/player/pipeline_marks.gd")


func _ready() -> void:
	var src := ""
	var dst := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--in="):
			src = a.substr(5)
		elif a.begins_with("--out="):
			dst = a.substr(6)
	var data = JSON.parse_string(FileAccess.get_file_as_string(src)) if src != "" else null
	if not (data is Dictionary) or dst == "":
		push_error("pipeline_predict: --in=<json> --out=<json> wanted")
		get_tree().quit(1)
		return
	var world := WorldMirror.new()
	world.pick_build_usec = 1 << 40
	world.protos.add_entities(data.get("protos", []))
	# As ui_model.gd reads `eprops`.
	var eprops := {}
	for r in data.get("eprops", []):
		if r is Array and r.size() >= 4:
			eprops[int(r[0])] = {"under": float(r[1]), "wire": float(r[2]), "supply": float(r[3]),
				"x": r[4] if r.size() > 4 and r[4] is Dictionary else {}}
	for r in data.get("records", []):
		if r is Array and r.size() >= 5:
			var c := WorldMirror.chunk_of(Vector2(float(r[2]), float(r[3])) / 256.0)
			if not world.chunks.has(c):
				world.chunks[c] = ChunkView.new()
			world._add(r)
	var groups := {}
	var n := 0
	for key in world.entities:
		var rec: WorldMirror.Rec = world.entities[key]
		if rec.unit == 0 or groups.has(str(rec.unit)) or not PipelineMarks.is_pipe(world, rec):
			continue
		n += 1
		var f := PipelineMarks.segment_from(world, rec, eprops)
		for u in f.units:
			groups[str(u)] = n
	var out := FileAccess.open(dst, FileAccess.WRITE)
	out.store_string(JSON.stringify({"groups": groups}))
	out.close()
	world.free()
	get_tree().quit(0)
