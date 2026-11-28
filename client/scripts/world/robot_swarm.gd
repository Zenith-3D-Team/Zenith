extends Node3D
## Flying robots drawn together (G3: the frame rate dropped with many robots in view). Each robot
## used to be a node with a MeshInstance3D per part and a flattened copy of each for its drop
## shadow, moved and animated one by one by vehicle_anim.gd: about 13 draw calls and objects a
## robot, and 9 ms of script a frame for 1,000 robots. Each robot kind is one MultiMesh per part
## (and one per part for the shadows).
##
## Where a robot is drawn and how it is animated (its bob, thrusters swung back as it flies, the
## cargo or empty lamp, a construction robot working with its arms out) come from its record
## (mover_records.gd), which movers.gd writes when a new position of it arrives: the robot shader
## (factorio_material_robot.gdshader) and the shadows' (robot_shadow.gdshader) work it all out.
## An instance holds only its record's slot (INSTANCE_CUSTOM.r) and is written when a robot comes
## or goes, so nothing here runs per robot per frame but a slice a frame of the cargo check and,
## ten times a second, construction robots at work throwing sparks.

const ModelLibrary := preload("res://scripts/world/model_library.gd")
const ModelLods := preload("res://scripts/world/model_lods.gd")
const VehicleAnim := preload("res://scripts/world/vehicle_anim.gd")
const MoverRecords := preload("res://scripts/world/mover_records.gd")
const Settings := preload("res://scripts/menu/settings.gd")
const RobotShader := preload("res://shaders/factorio_material_robot.gdshader")
const RobotAlphaShader := preload("res://shaders/factorio_material_robot_alpha.gdshader")
const ShadowShader := preload("res://shaders/robot_shadow.gdshader")
const Probing := preload("res://scripts/debug/probing.gd")
const Switches := preload("res://scripts/switches.gd")

## The robots drawn here: their models' parts are all this knows how to move. Combat robots have a
## body only and don't bob (vehicle_anim.gd never rigged them); capture robots' cables stay nodes.
const KINDS := {"logistic-robot": "logistic", "construction-robot": "construction"}
const PART_CODES := {"thrusters": 1, "lamp_cargo": 2, "lamp_empty": 3, "lamp_nozzle": 4, "arms": 5}
const STRIDE := 16  # floats an instance: a 3x4 transform, then INSTANCE_CUSTOM
## Instances are drawn wherever their records put them, so the MultiMeshes' own bounds (all at the
## origin) mean nothing: they are drawn wherever the camera looks (as their bounds round a swarm
## spread over a base mostly were anyway).
const BOUNDS := AABB(Vector3(-100000.0, -100.0, -100000.0), Vector3(200000.0, 400.0, 200000.0))
## Robots looked at a frame for cargo (ui_model.gd's robot_cargo), and seconds between looks at
## construction robots for work.
const CARGO_SLICE := 64
const WORK_LOOK := 0.1
const CHARGE_SPARK_EVERY := 0.22


class Bot:
	var unit := 0
	var batch: Batch
	var slot := 0  # its instance in the batch
	var record := -1  # its record (mover_records.gd)
	var phase := 0.0  # its bob's (in its record)
	var hidden := false  # movers.gd: the remote view's fog hides it (no sparks)
	var cargo := false
	var spark := 0.0
	var charging := false
	var charge_fx := 0.0


class Batch:
	var name := ""
	var kind := ""  # KINDS, or "" (a body only)
	var source: Mesh  # the model's body as ModelLibrary had it (rebuilt when that changes)
	var parts: Array[MultiMeshInstance3D] = []
	var shadows: Array[MultiMeshInstance3D] = []
	var bots: Array[Bot] = []
	## M3: each bot's record by its slot, kept as bots are added, placed and removed (bots[i].record).
	var slots := PackedInt32Array()
	var capacity := 0
	var buffer := PackedFloat32Array()
	var dirty := false
	var shown := -1
	var sweep := 0  # where the cargo check got to
	var mv_settle := 0
	var charging_count := 0


## ui_model.gd's robot_cargo and sprite_fx.gd's sparks, through vehicle_anim.gd (main.gd sets them there).
var vehicles: Node
## The movers' records (movers.gd sets it).
var records: MoverRecords

## False with --robot-nodes: robots are drawn the old way, a node each (for comparing).
static var enabled := not Switches.has("--robot-nodes")
## `--mv-skip-idle=off`: always re-write and re-upload batch buffers under FSR 2.2 / TAA.
static var mv_skip_idle := Switches.on("--mv-skip-idle")
## --mm-bounds=engine: the MultiMesh's own box left unset, as before; Godot then works its bounds out over
## every instance of its capacity at each buffer upload (perf-render R6). The node's box culls either way.
static var mm_own_bounds := not Switches.has("--mm-bounds=engine")
## M3 (--native-mover-sweep=off: each frame's record list rebuilt from the bots and the idle check in
## GDScript, as before): the batch's kept slots go to write_xforms and MoversNative.any_active.
static var native_sweep := not Switches.has("--native-mover-sweep=off")
## --robot-charge-sparks=off disables electric arcs and spark bursts on charging worker robots.
static var charge_sparks_default := Switches.on("--robot-charge-sparks")
var charge_sparks_enabled := charge_sparks_default
## The last frame's draw time, microseconds (--robot-probe).
var draw_usec := 0
var mv_uploads := 0

var _batches := {}  # proto name -> Batch
var _shadow_material: ShaderMaterial
var _look := 0.0
var _mv_active := false


## Whether robots of this prototype are drawn here (their model must be ready).
static func handles(proto_name: String, proto_type: String) -> bool:
	if not enabled or not (KINDS.has(proto_name) or proto_type == "combat-robot"):
		return false
	return ModelLibrary.mesh_for(proto_name) != null


func add(unit: int, proto_name: String) -> Bot:
	var batch: Batch = _batches.get(proto_name)
	if batch == null:
		batch = _make_batch(proto_name)
		_batches[proto_name] = batch
	var bot := Bot.new()
	bot.unit = unit
	bot.batch = batch
	bot.slot = batch.bots.size()
	bot.phase = float(posmod(unit * 7919, 1000)) / 1000.0 * TAU
	bot.cargo = _cargo().has(unit)
	batch.bots.append(bot)
	batch.slots.push_back(bot.record)
	return bot


## Its record's flags for a new robot: animated (not a combat robot), a builder, carrying cargo.
func flags_for(bot: Bot) -> int:
	var flags := 0
	if bot.batch.kind != "":
		flags |= MoverRecords.ANIMATED
	if bot.batch.kind == "construction":
		flags |= MoverRecords.BUILDER
	if bot.cargo:
		flags |= MoverRecords.CARGO
	return flags


## Its instance draws record `record` from now on.
func place(bot: Bot, record: int) -> void:
	bot.record = record
	var batch := bot.batch
	if batch == null:
		return
	if bot.slot < batch.slots.size():
		batch.slots[bot.slot] = record
	if batch.bots.size() > batch.capacity:
		_grow(batch, batch.bots.size())
	_write_instance(batch, bot.slot, record)
	batch.dirty = true


static func _write_instance(batch: Batch, i: int, record: int) -> void:
	var b := batch.buffer
	var o := i * STRIDE
	# A plain transform at the origin: the shader puts the robot where its record says.
	b[o] = 1.0
	b[o + 1] = 0.0
	b[o + 2] = 0.0
	b[o + 3] = 0.0
	b[o + 4] = 0.0
	b[o + 5] = 1.0
	b[o + 6] = 0.0
	b[o + 7] = 0.0
	b[o + 8] = 0.0
	b[o + 9] = 0.0
	b[o + 10] = 1.0
	b[o + 11] = 0.0
	b[o + 12] = float(record)
	b[o + 13] = 0.0
	b[o + 14] = 0.0
	b[o + 15] = 0.0


func set_charging(bot: Bot, on: bool) -> void:
	if bot == null or bot.charging == on:
		return
	bot.charging = on
	if on:
		bot.charge_fx = randf_range(0.0, 0.08)
	var batch := bot.batch
	if batch != null:
		batch.charging_count = maxi(0, batch.charging_count + (1 if on else -1))


func remove(bot: Bot) -> void:
	var batch := bot.batch
	if batch == null or bot.slot >= batch.bots.size() or batch.bots[bot.slot] != bot:
		return
	if bot.charging:
		bot.charging = false
		batch.charging_count = maxi(0, batch.charging_count - 1)
	var last: Bot = batch.bots[batch.bots.size() - 1]
	batch.bots[bot.slot] = last
	last.slot = bot.slot
	batch.bots.resize(batch.bots.size() - 1)
	if last.slot < batch.slots.size():
		batch.slots[last.slot] = last.record
	batch.slots.resize(batch.bots.size())
	if last != bot:
		_write_instance(batch, last.slot, last.record)
	batch.dirty = true
	bot.batch = null


func clear() -> void:
	for batch: Batch in _batches.values():
		_free_batch(batch)
		# Bots and their batch point at each other: let go of both, or neither is ever freed.
		for bot in batch.bots:
			bot.charging = false
			bot.batch = null
		batch.bots.clear()
		batch.slots.clear()
		batch.charging_count = 0
	_batches.clear()
	_mv_active = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for batch: Batch in _batches.values():
			for bot in batch.bots:
				bot.batch = null
			batch.bots.clear()


## Robots drawn (all kinds).
func count() -> int:
	var n := 0
	for batch: Batch in _batches.values():
		n += batch.bots.size()
	return n


## MultiMeshInstance3Ds drawing robots and their shadows (the UI test counts them).
func instances() -> Array[MultiMeshInstance3D]:
	var out: Array[MultiMeshInstance3D] = []
	for batch: Batch in _batches.values():
		out.append_array(batch.parts)
		out.append_array(batch.shadows)
	return out


## A robot as the shader draws it now: [transform, its animation as Color(flying, bob phase, flags,
## reach)], from the record its instance points at, or [] (the UI test).
func drawn(bot: Bot) -> Array:
	var batch := bot.batch
	if batch == null or records == null or batch.parts.is_empty() or bot.slot >= batch.bots.size():
		return []
	var record := int(batch.buffer[bot.slot * STRIDE + 12])
	var st := records.state(record)
	var anim := MoverRecords.robot_anim(st)
	return [Transform3D(Basis(Vector3.UP, st["yaw"]), st["pos"]), Color(anim.x, anim.y, anim.z, anim.w)]


## A model change (Settings > Graphics > Model look, a reload) gives the robots their new meshes.
## Batches whose model changed (ModelLibrary.generation) are made again on the new mesh, for at most
## `usec` a call (at least one; 0: all at once). True once every batch is on its current mesh.
func refresh(usec := 0) -> bool:
	var t0 := Time.get_ticks_usec()
	var made := 0
	for name in _batches.keys():
		var batch: Batch = _batches[name]
		if ModelLibrary.mesh_for(name) == batch.source:
			continue
		if usec > 0 and made > 0 and Time.get_ticks_usec() - t0 > usec:
			return false
		var bots := batch.bots
		_free_batch(batch)
		var fresh := _make_batch(name)
		fresh.bots = bots
		fresh.slots = batch.slots
		for bot in bots:
			bot.batch = fresh
		_grow(fresh, bots.size())
		for bot in bots:
			_write_instance(fresh, bot.slot, bot.record)
		fresh.dirty = true
		_batches[name] = fresh
		made += 1
	return true


## Once a frame (movers.gd): instances that came or went go to the MultiMeshes, cargo lamps follow
## ui_model.gd's robot_cargo, and working construction robots throw sparks.
func draw(delta: float) -> void:
	var started := Time.get_ticks_usec()
	_draw(delta)
	draw_usec = Time.get_ticks_usec() - started


func _draw(delta: float) -> void:
	var cargo := _cargo()
	_look -= delta
	var look := _look <= 0.0
	if look:
		_look = WORK_LOOK
	var vp: Viewport = get_viewport() if is_inside_tree() else null
	var want_mv := records != null and Settings.temporal_aa_active(vp)
	var c_even := 0.0
	var c_odd := 0.0
	var inv_rate := 1.0 / 60.0
	if want_mv:
		var cl := records.clocks()
		c_even = MoverRecords._f32(cl.x)
		c_odd = MoverRecords._f32(cl.y)
		inv_rate = 1.0 / maxf(records.rate, 1.0)
	for batch: Batch in _batches.values():
		var n := batch.bots.size()
		if n > batch.capacity:
			_grow(batch, n)
		if want_mv and n > 0:
			var nat := MoverRecords.native()
			var kept := native_sweep and nat != null and batch.slots.size() == n and nat.has_method("any_active")
			var active_now := true
			if mv_skip_idle:
				active_now = nat.call("any_active", records.data, batch.slots, n, c_even, c_odd, inv_rate) if kept \
						else _any_bot_active(batch, c_even, c_odd, inv_rate)
			var need_mv := not mv_skip_idle or not _mv_active or batch.dirty or batch.mv_settle > 0 or active_now
			if need_mv:
				if active_now:
					batch.mv_settle = 2
				elif batch.dirty or not _mv_active:
					batch.mv_settle = maxi(batch.mv_settle, 1)
				else:
					batch.mv_settle -= 1
				if nat != null:
					var slots := batch.slots
					if not kept:
						slots = PackedInt32Array()
						slots.resize(n)
						for i in n:
							slots[i] = (batch.bots[i] as Bot).record
					batch.buffer = nat.write_xforms(records.data, slots, n, batch.buffer, c_even, c_odd, inv_rate, 0)
					if nat.skipped() > 0:
						for i in n:
							if slots[i] < 0:
								_write_instance(batch, i, slots[i])
				else:
					for i in n:
						var bot: Bot = batch.bots[i]
						if bot.record >= 0:
							records.write_xform(bot.record, batch.buffer, i * STRIDE, c_even, c_odd, inv_rate)
							batch.buffer[i * STRIDE + 12] = float(bot.record)
							batch.buffer[i * STRIDE + 13] = 1.0
						else:
							_write_instance(batch, i, bot.record)
				batch.dirty = true
		elif _mv_active and not want_mv and n > 0:
			batch.mv_settle = 0
			for i in n:
				_write_instance(batch, i, batch.bots[i].record)
			batch.dirty = true
		if batch.dirty:
			batch.dirty = false
			for mmi in batch.parts:
				RenderingServer.multimesh_set_buffer(mmi.multimesh.get_rid(), batch.buffer)
			for mmi in batch.shadows:
				RenderingServer.multimesh_set_buffer(mmi.multimesh.get_rid(), batch.buffer)
			mv_uploads += 1
		if n != batch.shown:
			batch.shown = n
			for mmi in batch.parts:
				mmi.multimesh.visible_instance_count = n
				mmi.visible = n > 0
			for mmi in batch.shadows:
				mmi.multimesh.visible_instance_count = n
				mmi.visible = n > 0
		if n == 0 or records == null:
			continue
		if batch.kind != "":
			var end := mini(batch.sweep + CARGO_SLICE, n)
			for i in range(batch.sweep, end):
				var bot: Bot = batch.bots[i]
				if bot.record >= 0 and (int(records.data[bot.record * MoverRecords.FLOATS + 12]) & MoverRecords.SIMULATED) != 0:
					continue
				var has := cargo.has(bot.unit)
				if has != bot.cargo:
					bot.cargo = has
					records.set_flag(bot.record, MoverRecords.CARGO, has)
			batch.sweep = end if end < n else 0
		if look and batch.kind != "":
			if batch.kind == "construction":
				_sparks(batch, WORK_LOOK)
			if charge_sparks_enabled and batch.charging_count > 0:
				_charge_sparks(batch, WORK_LOOK)
	_mv_active = want_mv


## Construction robots standing still for VehicleAnim.WORK_STILL work: sparks fly from their nozzle
## now and then, as vehicle_anim.gd threw them. A robot stands once the clock is past its record's
## last point (robots are drawn stopping there until the next comes).
func _any_bot_active(batch: Batch, c_even: float, c_odd: float, inv_rate: float) -> bool:
	for bot in batch.bots:
		if _slot_active(records, bot.record, c_even, c_odd, inv_rate):
			return true
	return false


static func _slot_active(recs: MoverRecords, slot: int, c_even: float, c_odd: float, inv_rate: float) -> bool:
	if slot < 0:
		return false
	var d := recs.data
	var o := slot * MoverRecords.FLOATS
	if o + 28 >= d.size():
		return true
	var flags := int(d[o + 12])
	var now := c_odd if (flags & MoverRecords.ODD) != 0 else c_even
	var after := maxf(now - d[o + 15], 0.0)
	if after < 2.0:
		return true
	if (flags & MoverRecords.SIMULATED) != 0:
		if (flags & MoverRecords.SIM_ORBIT) != 0:
			return true
		if now < maxf(d[o + 9], d[o + 10]):
			return true
		var since := after * inv_rate
		if absf(d[o + 6]) + absf(d[o + 7]) > 1e-4 and exp(-d[o + 24] * since) > 1e-4:
			return true
		var had_leg2 := d[o + 10] > d[o + 9] + 1e-4
		var since_yaw := maxf(now - maxf(d[o + 15], d[o + 9]), 0.0) * inv_rate if had_leg2 else since
		var yaw_from := d[o + 14] if had_leg2 else d[o + 16]
		var yaw_to := d[o + 17] if had_leg2 else d[o + 14]
		return absf(wrapf(yaw_from - yaw_to, -PI, PI)) * exp(-MoverRecords.TURN_RATE * since_yaw) > 1e-4
	var since3 := after * inv_rate
	if absf(wrapf(d[o + 16] - d[o + 17], -PI, PI)) * exp(-MoverRecords.TURN_RATE * since3) > 1e-4:
		return true
	var l0: float = d[o + 24]
	var g0: float = d[o + 25]
	var gg: float = d[o + 26]
	var gap := move_toward(g0, gg, after * (d[o + 28] if gg > g0 else 1.0))
	var want := maxf(2.0 * gap, d[o + 27] + gap)
	var lag := minf(l0 + 0.5 * after, want) if want >= l0 else maxf(l0 - after, want)
	var drawn := now - lag
	var span3: float = d[o + 11] - d[o + 10]
	var end_drawn: float = d[o + 10] + d[o + 23] * span3 if span3 > 1e-4 else d[o + 11]
	return drawn < end_drawn


func _sparks(batch: Batch, step: float) -> void:
	var sprites: Node = vehicles.get("sprites") if vehicles != null else null
	if sprites == null:
		return
	var rate := maxf(records.rate, 1.0)
	var d := records.data
	for bot in batch.bots:
		if bot.hidden or bot.record < 0:
			continue
		var o := bot.record * MoverRecords.FLOATS
		var flags := int(d[o + 12])
		if (flags & MoverRecords.SIMULATED) != 0 and (flags & MoverRecords.SIM_WORKING) == 0:
			continue
		if (records.tick - records.last_tick(bot.record)) / rate <= VehicleAnim.WORK_STILL:
			continue
		bot.spark -= step
		if bot.spark > 0.0:
			continue
		bot.spark = VehicleAnim.SPARK_EVERY * randf_range(0.6, 1.4)
		var yaw: float
		var at: Vector3
		if (flags & MoverRecords.SIMULATED) != 0:
			at = records.position(bot.record)
			yaw = records.yaw_at(bot.record, records.tick)
		else:
			yaw = d[o + 17]
			at = Vector3(d[o + 6], d[o + 13], d[o + 7])
		sprites.call("emit", "sparks", at + Vector3(-0.35 * sin(yaw), 0.0, -0.35 * cos(yaw)), 0.45, 0.35)


static func emit_charge_sparks(sprites: Node, at: Vector3) -> void:
	if sprites == null:
		return
	var w_arc := randf_range(0.78, 0.96)
	var arc: Variant = sprites.call("emit", "roboport-charge",
		at + Vector3(randf_range(-0.12, 0.12), -0.18, randf_range(-0.12, 0.12)),
		w_arc, 0.36, Color(0.85, 0.96, 1.0, 0.95))
	if arc is Object:
		var arc_obj: Object = arc
		arc_obj.set("fps", 30.0)
		arc_obj.set("size1", w_arc * 1.12)
	var spk: Variant = sprites.call("emit", "sparks",
		at + Vector3(randf_range(-0.14, 0.14), -0.12, randf_range(-0.14, 0.14)),
		randf_range(0.34, 0.46), randf_range(0.22, 0.32), Color(0.55, 0.88, 1.0, 0.95))
	if spk is Object:
		var spk_obj: Object = spk
		var ang := randf() * TAU
		var spd := randf_range(0.25, 0.65)
		spk_obj.set("vel", Vector3(cos(ang) * spd, randf_range(0.15, 0.55), sin(ang) * spd))
		spk_obj.set("rise", -2.4)


func _charge_sparks(batch: Batch, step: float) -> void:
	if batch.charging_count <= 0:
		return
	var sprites: Node = vehicles.get("sprites") if vehicles != null else null
	if sprites == null:
		return
	for bot: Bot in batch.bots:
		if not bot.charging or bot.hidden or bot.record < 0:
			continue
		bot.charge_fx -= step
		if bot.charge_fx > 0.0:
			continue
		bot.charge_fx = CHARGE_SPARK_EVERY * randf_range(0.7, 1.3)
		emit_charge_sparks(sprites, records.position(bot.record))


func _cargo() -> Dictionary:
	var model = vehicles.get("model") if vehicles != null else null
	if model == null:
		return {}
	var cargo = model.get("robot_cargo") if model is Object else model.get("robot_cargo", {})
	return cargo if cargo is Dictionary else {}


func _grow(batch: Batch, needed: int) -> void:
	var capacity := maxi(64, batch.capacity)
	while capacity < needed:
		capacity *= 2
	if capacity == batch.capacity:
		return
	batch.capacity = capacity
	batch.buffer.resize(capacity * STRIDE)
	for mmi in batch.parts:
		mmi.multimesh.instance_count = capacity
	for mmi in batch.shadows:
		mmi.multimesh.instance_count = capacity
	batch.shown = -1
	batch.dirty = true


func _make_batch(proto_name: String) -> Batch:
	var batch := Batch.new()
	batch.name = proto_name
	batch.kind = KINDS.get(proto_name, "")
	batch.source = ModelLibrary.mesh_for(proto_name)
	if batch.source == null:
		return batch
	var meshes: Array = [[batch.source, 0, Transform3D.IDENTITY]]
	for part: ModelLibrary.AnimPart in ModelLibrary.parts_for(proto_name):
		meshes.append([part.mesh, int(PART_CODES.get(part.kind, 0)), part.pivot])
	for entry in meshes:
		var mesh: Mesh = entry[0]
		if mesh == null:
			continue
		var t0 := Time.get_ticks_usec()
		var robot_mesh := _robot_mesh(mesh, int(entry[1]), entry[2], batch.kind != "")
		Probing.add("rb_mesh", t0)
		t0 = Time.get_ticks_usec()
		batch.parts.append(_instance(robot_mesh, null))
		batch.shadows.append(_instance(mesh, _shadow()))
		Probing.add("rb_instances", t0)
	return batch


func _instance(mesh: Mesh, material: Material) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF  # the drop shadow is the shadow
	mmi.custom_aabb = BOUNDS
	if mm_own_bounds:
		mm.custom_aabb = BOUNDS
	if material != null:
		mmi.material_override = material
	add_child(mmi)
	return mmi


## A copy of a part's mesh whose model materials use the robot shader, told which part it is.
## Built from the CPU arrays and copied materials: duplicate() reads both back from the
## RenderingServer, which waits for the render thread when it runs on its own.
static func _robot_mesh(mesh: Mesh, code: int, pivot: Transform3D, bobs: bool) -> Mesh:
	var out := ArrayMesh.new()
	var source := mesh as ArrayMesh
	for i in mesh.get_surface_count():
		var custom := source.surface_get_format(i) & ModelLods.CUSTOM_FORMATS if source != null else 0
		var t0 := Time.get_ticks_usec()
		var arrays := ModelLods.arrays_of(mesh, i)
		Probing.add("rb_arrays", t0)
		t0 = Time.get_ticks_usec()
		out.add_surface_from_arrays(mesh.surface_get_primitive_type(i), arrays, [], {}, custom)
		out.surface_set_material(i, mesh.surface_get_material(i))
		Probing.add("rb_surface", t0)
	var tm := Time.get_ticks_usec()
	for i in out.get_surface_count():
		var material := out.surface_get_material(i) as ShaderMaterial
		var alpha := material != null and material.shader == ModelLibrary.FactorioAlphaShader
		var copy: ShaderMaterial
		if material != null and (alpha or material.shader == ModelLibrary.FactorioShader):
			copy = ModelLods.copy_material(material)
		else:
			# Every part must read the robot's record to be drawn where it is: a material of another
			# kind becomes a plain one of the robot shader in its colour.
			copy = ShaderMaterial.new()
			copy.shader = RobotShader
			var plain := out.surface_get_material(i) as BaseMaterial3D
			copy.set_shader_parameter("albedo", plain.albedo_color if plain != null else Color(0.5, 0.5, 0.5))
			copy.set_shader_parameter("vertex_data", 0.0)
			copy.set_shader_parameter("edge_data", 0.0)
			copy.set_shader_parameter("view_data", 0.0)
		copy.shader = RobotAlphaShader if alpha else RobotShader
		copy.set_shader_parameter("robot_part", code)
		copy.set_shader_parameter("robot_pivot", pivot.origin)
		copy.set_shader_parameter("robot_axis", pivot.basis.x.normalized())
		copy.set_shader_parameter("robot_bob", VehicleAnim.ROBOT_BOB if bobs else 0.0)
		copy.set_shader_parameter("robot_bob_rate", VehicleAnim.ROBOT_BOB_RATE)
		out.surface_set_material(i, copy)
	Probing.add("rb_materials", tm)
	return out


func _shadow() -> ShaderMaterial:
	if _shadow_material == null:
		_shadow_material = ShaderMaterial.new()
		_shadow_material.shader = ShadowShader
	return _shadow_material


func _free_batch(batch: Batch) -> void:
	for mmi in batch.parts:
		mmi.queue_free()
	for mmi in batch.shadows:
		mmi.queue_free()
	batch.parts.clear()
	batch.shadows.clear()
