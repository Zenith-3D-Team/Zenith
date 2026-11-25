extends RefCounted
## The Model packs window's preview playing its model's moving parts (model_preview.gd set_playing):
## as the world draws them. The world's model shader moves a part, lights a glow and scrolls a belt
## from each instance's custom data (anim.gd), which only a MultiMesh instance has, so each mesh of
## the preview that moves is drawn here as a MultiMesh of one instance, its MeshInstance3D hidden,
## and an animator of its own (anim.gd, out of the tree) writes that instance's state as the world's
## writes an entity's: working, on its clock. The clock is the world's animator's when a game runs
## (the shader's f3d_anim_time is global to every viewport), else this one's, which then writes it.
##
## A modeller's baked part (model_skin.gd: a splitter's gears and belts, a belt's rollers) is already a
## MultiMesh of one in the preview, skinned at rest (model_preview.gd part_node): it is timed in place,
## not copied, so its bones' setup stays, and put back at rest (PART_AT_REST) when it stops.
##
## At rest a belt's surface stands still (the world's switched-off belt, anim.gd BELT_STOPPED): the
## shader scrolls any belt surface without custom data.
##
## An inserter's arm (model_preview.gd's `arm_piece` nodes) swings as a working one does in the game: it
## takes an item over its pickup, swings round to its drop at its prototype's rotation and extension speeds
## (inserter_swing.gd, the world's own legs), lets go and swings back, in a loop; each frame posed by
## inserter_arms.gd posed_pieces (the world's _draw_* calls: a rig's IK and pincers, Wube's pieces, the
## plain arm), the pincers eased as the world's (ease_close), an iron plate in the hand while it carries.
## `arm_moving` is the world's (L4) rule for the hand moving, told to the animator as inserter_arms.gd
## tells the world's. Stopped, the arm is posed at rest again. The Factorio pack's inserter (its pictures,
## model_preview.gd's `arm_model`) swings the same way: posed_pieces gives its arm's cards (Factorio's hand base
## and open or closed hand), each node's unshaded picture following its hand (`card_unlit`), for its picture's
## direction `arm_dir` (its pickup and drop turned with it, as the world's).
##
## A rail or chain signal (SIGNAL_CYCLES) lights its lamps by the state the bridge's `st` gives the world's
## (anim.gd LIT_STATES): playing, each of its colours in turn, SIGNAL_HOLD seconds each, set as the
## world sets it (the entity's working state), so any pack's `anim_lit_*` lamps follow; at rest the state of
## a signal with no train, green (1), as the world shows an idle one.

const Anim := preload("res://scripts/world/anim.gd")
const ModelLibrary := preload("res://scripts/world/model_library.gd")
const InserterArms := preload("res://scripts/world/inserter_arms.gd")
const Swing := preload("res://scripts/world/inserter_swing.gd")
const ItemModels := preload("res://scripts/world/item_models.gd")
const SpriteStandins := preload("res://scripts/world/sprite_standins.gd")
const VehicleAnim := preload("res://scripts/world/vehicle_anim.gd")
## The ticks the hand stands at each end, the item taken (or let go) ARM_TAKE ticks after it arrives.
const ARM_WAIT := 12.0
const ARM_TAKE := 2.0
const ARM_ITEM := "iron-plate"

## The preview's entity, to the animator: one key, one unit, working.
const KEY := "model-preview"
const UNIT := -1
## A timed moving part at rest, as anim.gd writes an idle instance's custom data: its clock at 0, no
## loops gone, no flags (the shader's `timed`, INSTANCE_CUSTOM.b < -0.5), full glow.
const PART_AT_REST := Color(0.0, 0.0, -1.0, 1.0)

var playing := false
## The copies drawn in the originals' place (MultiMeshInstance3D), their groups, the originals hidden.
var copies: Array[MultiMeshInstance3D] = []
var groups: Array = []
var _hidden: Array[Node3D] = []
var _anim: Anim = null
var _own_time := 0.0
var _working := {UNIT: 1}
var _rest := {}  # a copy at rest -> its custom data
var _tracks: Array = []  # [[MultiMeshInstance3D, track_x], ...] for tank treads
var _track_travel := 0.0
## The baked parts timed in place while playing (the preview's own MultiMeshInstance3D).
var in_place: Array[MultiMeshInstance3D] = []
## (An inserter) Whether its hand is moving now (inserter_arms.gd _moving's rule: drawn turning or reaching,
## or within its MOVING_HOLD ticks of it), as the world's animator's arm_working says for a live arm.
var arm_moving := false
## (An inserter) The hand's pose now: where (tiles from its middle, facing north), its pincers (0 open, 1
## closed) and whether it holds the item.
var hand := Vector2.ZERO
var close := 0.0
var holding := false
var _arm_nodes: Array = []  # the arm_piece nodes (untyped: a model shown frees them)
var _arm_model := ""
## (A picture's arm) The 16-way direction its picture faces.
var arm_dir := 0
var _arm_posing = null  # an InserterArms out of the tree (new_posing)
var _arm_keys: Array = []  # one cycle's keyframes (inserter_swing.gd)
var _arm_cycle := 1.0  # its length, ticks
var _arm_tick := 0.0  # into the cycle
var _arm_clock := 0.0  # ticks played (_moving's clock)
var _arm_seen = null  # InserterArms.Arm: the pose drawn last, for _moving
var _rest_hand := Vector2.ZERO
var _held: MeshInstance3D = null
## (A rail or chain signal) The states its lamps go through playing (st: 1 green, 2 yellow, 3 red, 4 blue)
## and the seconds into the cycle.
const SIGNAL_CYCLES := {"rail-signal": [1, 2, 3], "rail-chain-signal": [1, 2, 3, 4]}
const SIGNAL_HOLD := 2.0
const SIGNAL_IDLE := 1
var signal_cycle: Array = []
var _signal_t := 0.0


## Whether the model in `holder` (its body, parts and end pieces, as model_preview.gd puts them) has
## anything that moves or glows while it works.
static func can_play(holder: Node3D, model: String) -> bool:
	for part: ModelLibrary.AnimPart in ModelLibrary.parts_for(model):
		Anim.setup_part(part)
		if part.mesh != null and (part.motion > Anim.MOTION_NONE \
				or (VehicleAnim.enhanced and (part.kind == "tread_l" or part.kind == "tread_r"))):
			return true
	for c in holder.get_children():
		if c.has_meta("arm_piece"):
			return true  # an inserter's arm swings
		var mi := c as MeshInstance3D
		if mi != null and mi.mesh != null and (_glows(mi.mesh) or _belt(mi.mesh)):
			return true
		if _baked_part(c) != null:
			return true
	return false


## A baked part the preview draws skinned (its MultiMesh of one), with its AnimPart; else null.
static func _baked_part(n: Node) -> ModelLibrary.AnimPart:
	if not (n is MultiMeshInstance3D) or not n.has_meta("anim_part"):
		return null
	var part: ModelLibrary.AnimPart = n.get_meta("anim_part")
	if part == null:
		return null
	Anim.setup_part(part)
	return part if part.motion > Anim.MOTION_NONE else null


## A mesh with a surface that glows while working (a furnace's fire, a lamp's glass).
static func _glows(mesh: Mesh) -> bool:
	for i in mesh.get_surface_count():
		var m := mesh.surface_get_material(i) as ShaderMaterial
		if m != null and m.get_shader_parameter("activity_glow") == true:
			return true
	return false


## A mesh with a belt surface (the shader's belt_speed scrolls it).
static func _belt(mesh: Mesh) -> bool:
	for i in mesh.get_surface_count():
		var m := mesh.surface_get_material(i) as ShaderMaterial
		if m != null:
			var speed: Variant = m.get_shader_parameter("belt_speed")
			if speed != null and float(speed) != 0.0:
				return true
	return false


## Draws `holder`'s model playing or at rest: playing, every moving or glowing mesh and the lit parts
## through the animator from rest; at rest only the belts, standing still. Again whenever the model's
## meshes change.
func build(holder: Node3D, model: String, play: bool) -> void:
	clear()
	playing = play
	if holder == null or model == "":
		return
	signal_cycle = SIGNAL_CYCLES.get(ModelLibrary.file_of(model), [])
	_signal_t = 0.0
	_working = {UNIT: SIGNAL_IDLE if not signal_cycle.is_empty() else 1}
	if play or not signal_cycle.is_empty():
		_anim = Anim.new()
		_own_time = 0.0
		_tick(holder)
	var parts := {}
	for part: ModelLibrary.AnimPart in ModelLibrary.parts_for(model):
		Anim.setup_part(part)
		if part.mesh != null:
			parts[part.mesh] = part
	if play:
		_start_arm(holder, model)
	for c in holder.get_children():
		if c.has_meta("arm_piece"):
			continue
		var baked := _baked_part(c)
		if baked != null:
			parts.erase((c as MultiMeshInstance3D).multimesh.mesh)
			if play:
				_time_in_place(c as MultiMeshInstance3D, baked)
			continue
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null or not mi.visible:
			continue
		var part: ModelLibrary.AnimPart = parts.get(mi.mesh)
		parts.erase(mi.mesh)
		if play and VehicleAnim.enhanced and part != null and (part.kind == "tread_l" or part.kind == "tread_r"):
			var tmm := VehicleAnim.build_track_mm(part)
			if tmm != null:
				tmm.transform = mi.transform
				holder.add_child(tmm)
				copies.append(tmm)
				_tracks.append([tmm, part.pivot.origin.x])
				_hide(mi)
				continue
		var moves := part != null and part.motion > Anim.MOTION_NONE
		if play and (moves or _glows(mi.mesh) or _belt(mi.mesh)):
			_copy(holder, mi.mesh, mi.transform, part if moves else null)
			_hide(mi)
		elif not play and part == null and _belt(mi.mesh):
			var mmi := _copy(holder, mi.mesh, mi.transform, null)
			mmi.multimesh.set_instance_custom_data(0, Anim.BELT_STOPPED)
			_rest[mmi] = Anim.BELT_STOPPED
			_hide(mi)
	# Lit parts (a signal's lamps, an accumulator's glow) aren't drawn at rest: lit while it works. A
	# signal's are, lit by its idle state.
	if play or not signal_cycle.is_empty():
		for part: ModelLibrary.AnimPart in parts.values():
			if part.lit and part.motion > Anim.MOTION_NONE:
				_copy(holder, part.mesh, Transform3D.IDENTITY, part)


## Puts the originals back and frees the copies (the next build starts from rest).
func clear() -> void:
	_stop_arm()
	for mmi in copies:
		if is_instance_valid(mmi):
			if mmi.get_parent() != null:
				mmi.get_parent().remove_child(mmi)
			mmi.queue_free()
	for n in _hidden:
		if is_instance_valid(n):
			n.visible = true
	for mmi in in_place:
		if is_instance_valid(mmi):
			mmi.multimesh.set_instance_custom_data(0, PART_AT_REST)
	in_place.clear()
	copies.clear()
	groups.clear()
	_rest.clear()
	_tracks.clear()
	_track_travel = 0.0
	_hidden.clear()
	if _anim != null:
		_anim.free()  # a Node out of the tree: its last reference going doesn't free it
	_anim = null
	playing = false


## A frame while playing: the animator's clock moves on (the world's, or its own by `delta`), and its
## instances are written again on a new epoch.
func process(holder: Node3D, delta: float) -> void:
	if _anim == null:
		return
	_own_time += delta
	_swing_arm(delta)
	if playing and not _tracks.is_empty():
		_track_travel += delta * Anim.PREVIEW_ROLL_SPEED
		for tr in _tracks:
			var t_pair: Array = tr
			VehicleAnim.update_track_mm(t_pair[0], float(t_pair[1]), _track_travel)
	var changed := _signal_cycle(delta)
	if _tick(holder) or changed:
		for g in groups:
			Anim.place(g, _anim, _working)


## (A rail or chain signal, playing) The cycle `delta` seconds on; whether its state changed (its
## lamps then written again, as the world's are when `st` changes).
func _signal_cycle(delta: float) -> bool:
	if signal_cycle.is_empty() or not playing:
		return false
	_signal_t = fmod(_signal_t + delta, SIGNAL_HOLD * signal_cycle.size())
	var state: int = signal_cycle[int(_signal_t / SIGNAL_HOLD) % signal_cycle.size()]
	if state == int(_working[UNIT]):
		return false
	_working[UNIT] = state
	return true


## The state a signal's lamps are lit by now (the world's `st`), 0 when it isn't one (the tests).
func signal_state() -> int:
	return int(_working[UNIT]) if not signal_cycle.is_empty() else 0


## The animator's time now; whether it moved onto a new epoch.
func _tick(holder: Node3D) -> bool:
	var world_anim := _world_animator(holder)
	if world_anim != null:
		return _anim.set_time(world_anim.now(), false)
	return _anim.set_time(_own_time, true)


## The world's animator when a game runs (it writes the shader's clock), else null.
static func _world_animator(holder: Node3D) -> Anim:
	if holder == null or not holder.is_inside_tree():
		return null
	var a := holder.get_tree().root.find_child("Animator", true, false)
	return a as Anim if a != null and a.get_script() == Anim and a.is_inside_tree() else null


## A copy's custom data as last written (the tests: the RenderingServer isn't read back).
func custom_of(mmi: MultiMeshInstance3D) -> Color:
	for g in groups:
		if g.mm == mmi.multimesh:
			return g.customs[0]
	if mmi.has_meta("anim_part"):
		return PART_AT_REST
	return _rest.get(mmi, Color(0.0, 0.0, 0.0, 0.0))


## The animator's clock now (the tests).
func time() -> float:
	return _anim.now() if _anim != null else 0.0


func _hide(mi: MeshInstance3D) -> void:
	mi.visible = false
	_hidden.append(mi)


## A baked part timed where it is: its own MultiMesh written by the animator, as a working entity's.
func _time_in_place(mmi: MultiMeshInstance3D, part: ModelLibrary.AnimPart) -> void:
	in_place.append(mmi)
	groups.append(_group(mmi.multimesh, part))


func _group(mm: MultiMesh, part: ModelLibrary.AnimPart) -> Anim.Group:
	var g := Anim.Group.new()
	g.mm = mm
	g.part = part
	g.keys.append(KEY)
	g.units.append(UNIT)
	g.bases.append(Transform3D.IDENTITY)
	g.stateful.append(Anim.STATE_REPORTED)
	g.customs.append(Color(0.0, 0.0, 0.0, 1.0))
	Anim.place(g, _anim, _working)
	return g


func _copy(holder: Node3D, mesh: Mesh, xf: Transform3D, part: ModelLibrary.AnimPart) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = 1
	mm.set_instance_transform(0, Transform3D.IDENTITY)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Playing%d" % copies.size()
	mmi.multimesh = mm
	mmi.transform = xf
	holder.add_child(mmi)
	copies.append(mmi)
	if _anim != null:
		groups.append(_group(mm, part))
	return mmi


## (An inserter) Playing starts: its arm's pieces found, one working cycle planned from its pickup to its
## drop and back at its prototype's speeds (the game's eprops when a game runs, else Factorio 2.1's).
func _start_arm(holder: Node3D, model: String) -> void:
	_arm_nodes.clear()
	for c in holder.get_children():
		if c.has_meta("arm_piece"):
			_arm_nodes.append(c)
	if _arm_nodes.is_empty():
		return
	_arm_model = model
	_arm_posing = InserterArms.new_posing()
	var proto := ModelLibrary.file_of(model)
	var cycle := InserterArms.cycle_of(proto, _eprops(holder, proto))
	var pick: Vector2 = InserterArms._turn(cycle["pick"], arm_dir)
	var drop: Vector2 = InserterArms._turn(cycle["drop"], arm_dir)
	var omega: float = cycle["omega"]
	var v: float = cycle["v"]
	_rest_hand = pick
	var ap := pick.angle()
	var rp := pick.length()
	# Round by the east (the sweep's side): a half turn either way is the same.
	var ad := ap + Swing.delta(ap, drop.angle(), 0.0)
	var rd := drop.length()
	var travel := float(maxi(1, Swing.travel_ticks(ad - ap, rd - rp, omega, v)))
	var there := ARM_WAIT + travel
	var back := there + ARM_WAIT
	_arm_cycle = back + travel
	_arm_keys = [[0.0, ap, rp, 0], [ARM_TAKE, ap, rp, 1], [ARM_WAIT, ap, rp, 1]]
	_arm_keys.append_array(Swing.leg(ARM_WAIT, ap, rp, there, ad, rd, 1, omega, v, true))
	_arm_keys.append([there + ARM_TAKE, ad, rd, 0])
	_arm_keys.append([back, ad, rd, 0])
	_arm_keys.append_array(Swing.leg(back, ad, rd, _arm_cycle, ap, rp, 0, omega, v, true))
	_arm_tick = 0.0
	_arm_clock = 0.0
	_arm_seen = InserterArms.Arm.new()
	hand = pick
	close = 0.0
	holding = false
	var mesh := ItemModels.mesh_for(ARM_ITEM)
	if mesh != null:
		var material := ItemModels.plain_material(mesh)
		_held = MeshInstance3D.new()
		_held.name = "HeldItem"
		_held.mesh = ItemModels.preview_mesh(mesh)
		_held.material_override = material
		_held.visible = false
		holder.add_child(_held)


## A frame of the swing: the cycle `delta` seconds on (60 ticks a second), the arm posed there.
func _swing_arm(delta: float) -> void:
	if _arm_posing == null:
		return
	var ticks := delta * 60.0
	_arm_clock += ticks
	_arm_tick = fmod(_arm_tick + ticks, _arm_cycle)
	var pose := Swing.at(_arm_keys, _arm_tick)
	hand = Swing.hand_pos(pose[0], pose[1])
	holding = int(pose[2]) != 0
	close = InserterArms.ease_close(close, holding, delta)
	_pose_arm()
	_arm_seen.angle = wrapf(pose[0], -PI, PI)
	_arm_seen.reach = pose[1]
	var moving: bool = InserterArms._moving(_arm_seen, _arm_clock)
	if moving != arm_moving:
		arm_moving = moving
		if _anim != null:
			_anim.arm_moving({"unit": UNIT}, moving)


## The arm's pieces put where posed_pieces has them for the pose now, the item in its grip while held.
func _pose_arm() -> void:
	var posed = _arm_posing.posed_pieces(_arm_model, hand, close, holding, arm_dir)
	if not (posed is Dictionary) or (posed as Dictionary).is_empty():
		return
	var pieces: Array = posed["pieces"]
	for n in _arm_nodes:
		if not is_instance_valid(n):
			continue
		var i: int = n.get_meta("arm_piece")
		if i >= pieces.size():
			continue
		n.transform = pieces[i][1]
		var mi := n as MeshInstance3D
		if mi != null and mi.mesh != pieces[i][0]:
			mi.mesh = pieces[i][0]  # (Wube's hand: open or closed)
			if mi.has_meta("card_unlit"):
				mi.material_override = SpriteStandins.unlit_material((mi.mesh as PrimitiveMesh).material)
	if _held != null and is_instance_valid(_held):
		_held.visible = holding
		# As inserter_arms.gd held_at: the item's middle in the grip, else hanging under the wrist.
		var grip: Vector3 = posed["grip"]
		var wrist: Vector3 = posed["wrist"]
		var at := grip - Vector3(0.0, clampf(_held.mesh.get_aabb().size.y, 0.03, 0.2) * 0.5, 0.0) if posed["gripped"] \
			else wrist - Vector3(0.0, InserterArms.ITEM_DROP, 0.0)
		_held.transform = Transform3D(posed["turn"] as Basis, at)


## Playing stops: the arm posed at rest again (the hand open over the pickup), the item gone.
func _stop_arm() -> void:
	if _arm_posing != null:
		hand = _rest_hand
		close = 0.0
		holding = false
		_pose_arm()
		InserterArms._free_scratch(_arm_posing)
	_arm_posing = null
	_arm_nodes.clear()
	if _held != null and is_instance_valid(_held):
		if _held.get_parent() != null:
			_held.get_parent().remove_child(_held)
		_held.queue_free()
	_held = null
	if arm_moving and _anim != null:
		_anim.arm_moving({"unit": UNIT}, false)
	arm_moving = false


## The inserter's eprops overlay from the world's arms when a game has sent them, else {}.
static func _eprops(holder: Node3D, proto: String) -> Dictionary:
	if holder == null or not holder.is_inside_tree():
		return {}
	var arms := holder.get_tree().root.find_child("InserterArms", true, false)
	if arms == null or arms.get_script() != InserterArms or arms.get("protos") == null:
		return {}
	var p = arms.protos.entities_by_name.get(proto)
	if p == null:
		return {}
	return (arms.eprops.get(p.id, {}) as Dictionary).get("x", {})
