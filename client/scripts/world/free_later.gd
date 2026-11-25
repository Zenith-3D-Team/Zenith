extends RefCounted
## Nodes and big resources let go a few at a time, inside a time slice a frame, instead of all in the
## frame they went (queue_free frees every node queued in one go between the scripts and the draw: the
## owner's spike log had 20-78 ms of "deferred+frees" in the frames far chunks merged and chunks
## streamed). A node given here is hidden at once and freed later; a resource (an old merged mesh) is
## kept until its turn, so its GPU buffers go a few a frame too. world.gd's _process calls step().
##
## --free-later=off: queue_free and dropped references at once, as before.
## --free-later-leaves=off: a node freed whole with its children in one call, its meshes with it (as
## frame-spikes2 had it: one big chunk's free could be 20 ms in a frame whose slice was 1 ms).

const Probing := preload("res://scripts/debug/probing.gd")
const Switches := preload("res://scripts/switches.gd")

static var on := Switches.on("--free-later")
## A waiting node's tree taken apart leaf by leaf and its meshes let go one a step, the clock read after
## each, so no single free() holds a frame (the owner's spike log: World 27 ms, its timed parts 5).
static var leaves := Switches.on("--free-later-leaves")
## The slice a frame (µs); at least one thing goes each frame something waits.
const SLICE_USEC := 1000
## More than this waiting: the slice doubles (a big unload must not pile up for seconds).
const BACKLOG := 512

static var _nodes: Array = []
static var _at := 0
static var _res: Array = []
static var freed := 0  # (debug) things let go so far


## Hides `node` and frees it within a later frame's slice (queue_free when off, or not in a tree).
static func node(n: Node) -> void:
	if n == null or not is_instance_valid(n):
		return
	if not on or not n.is_inside_tree():
		n.queue_free()
		return
	if n is Node3D:
		(n as Node3D).visible = false
	elif n is CanvasItem:
		(n as CanvasItem).visible = false
	n.set_process(false)
	n.set_physics_process(false)
	_nodes.append(n)


## Keeps `res` (a mesh, a MultiMesh, a texture whose last user went) until a later frame's slice.
static func resource(r: Resource) -> void:
	if r == null or not on:
		return
	_res.append(r)


## How many wait.
static func waiting() -> int:
	return _nodes.size() - _at + _res.size()


## Frees what waits, SLICE_USEC's worth (twice that with a backlog). Its time and its slowest single
## free go to Probing (the spike log's parts fl_step, fl_one_<class>).
static func step() -> void:
	if _at >= _nodes.size() and _res.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var slice := SLICE_USEC * (2 if waiting() > BACKLOG else 1)
	var worst := 0
	var worst_what := ""
	while not _res.is_empty():
		var tr := Time.get_ticks_usec()
		_res.pop_back()
		freed += 1
		var d := Time.get_ticks_usec() - tr
		if d > worst:
			worst = d
			worst_what = "res"
		if Time.get_ticks_usec() - t0 > slice:
			_note(t0, worst, worst_what)
			return
	while _at < _nodes.size():
		var nd: Variant = _nodes[_at]
		if not is_instance_valid(nd):
			_nodes[_at] = null
			_at += 1
			continue
		var target := nd as Node
		var whole := true
		if leaves:
			# Its deepest last child first (the node itself once bare): one leaf a free.
			while target.get_child_count() > 0:
				target = target.get_child(target.get_child_count() - 1)
			whole = target == nd
		var tf := Time.get_ticks_usec()
		var what := target.get_class()
		if leaves and _shed(target):
			what += " mesh"
		else:
			if whole:
				_nodes[_at] = null
				_at += 1
			target.free()
		freed += 1
		var d := Time.get_ticks_usec() - tf
		if d > worst:
			worst = d
			worst_what = what
		if Time.get_ticks_usec() - t0 > slice:
			break
	if _at >= _nodes.size():
		_nodes.clear()
		_at = 0
	elif _at > 256:
		_nodes = _nodes.slice(_at)
		_at = 0
	_note(t0, worst, worst_what)


## A mesh instance's mesh or MultiMesh taken off it into the resources' queue (its buffers then go in a
## step of their own); true when there was one.
static func _shed(n: Node) -> bool:
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		_res.append((n as MeshInstance3D).mesh)
		(n as MeshInstance3D).mesh = null
		return true
	if n is MultiMeshInstance3D and (n as MultiMeshInstance3D).multimesh != null:
		_res.append((n as MultiMeshInstance3D).multimesh)
		(n as MultiMeshInstance3D).multimesh = null
		return true
	return false


static func _note(t0: int, worst: int, what: String) -> void:
	if not Probing.on:
		return
	Probing.add("fl_step", t0)
	if worst >= 1000:
		Probing.prof["fl_one_" + what.replace(" ", "_")] = int(Probing.prof.get("fl_one_" + what.replace(" ", "_"), 0)) + worst


## Quit (world.gd's _exit_tree): the resources held let go now, while the RenderingServer is still up,
## not at script shutdown; the nodes waiting are left to the tree, which frees them with their parents
## (free() here, with the parents busy leaving the tree, errors). A game left needs nothing: step() goes
## on freeing them a slice a frame.
static func drop() -> void:
	_nodes.clear()
	_at = 0
	_res.clear()


## Everything at once (tests).
static func flush() -> void:
	for i in range(_at, _nodes.size()):
		var nd: Variant = _nodes[i]
		if is_instance_valid(nd):
			(nd as Node).free()
	_nodes.clear()
	_at = 0
	_res.clear()
