extends Node
## --mem-log[=<seconds>]: prints where the client's memory is every <seconds> (10 unless said), with
## nothing else running (no walking, no windows: soak_probe.gd does that). One line a sample:
##   MEM t=40 static=1041 video=2210 tex=1800 buf=380 objects=76454 nodes=5725 res=448 orphans=12
##       pipes canvas=12 mesh=300 surface=900 draw=40 spec=1200
## static is Godot's own allocator (scripts, nodes, resources, native classes that use it); video,
## tex and buf are the renderer's GPU allocations (0 headless: the dummy renderer has none); pipes
## are the render pipelines compiled since start by kind (each one also costs the GPU driver memory
## that no Godot figure shows). Compare the process's RSS (Task Manager, bench tools) with these:
## what RSS has beyond static + video is the driver's and the native libraries' own.

var every := 10.0
var _left := 0.0
var _t := 0.0


func _process(delta: float) -> void:
	_t += delta
	_left -= delta
	if _left > 0.0:
		return
	_left = every
	print(line(_t))


static func line(t: float) -> String:
	var mb := func(m: int) -> int: return int(Performance.get_monitor(m) / 1048576.0)
	var n := func(m: int) -> int: return int(Performance.get_monitor(m))
	return ("MEM t=%d static=%d video=%d tex=%d buf=%d objects=%d nodes=%d res=%d orphans=%d"
		+ " pipes canvas=%d mesh=%d surface=%d draw=%d spec=%d") % [
		int(t), mb.call(Performance.MEMORY_STATIC), mb.call(Performance.RENDER_VIDEO_MEM_USED),
		mb.call(Performance.RENDER_TEXTURE_MEM_USED), mb.call(Performance.RENDER_BUFFER_MEM_USED),
		n.call(Performance.OBJECT_COUNT), n.call(Performance.OBJECT_NODE_COUNT),
		n.call(Performance.OBJECT_RESOURCE_COUNT), n.call(Performance.OBJECT_ORPHAN_NODE_COUNT),
		n.call(Performance.PIPELINE_COMPILATIONS_CANVAS), n.call(Performance.PIPELINE_COMPILATIONS_MESH),
		n.call(Performance.PIPELINE_COMPILATIONS_SURFACE), n.call(Performance.PIPELINE_COMPILATIONS_DRAW),
		n.call(Performance.PIPELINE_COMPILATIONS_SPECIALIZATION)]
