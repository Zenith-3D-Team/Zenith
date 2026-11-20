extends RefCounted
## A modeller's burner inserter's lit burner (Vasillo's burner-inserter.glb: a yellow-orange grille in
## its base, an emissive material), while it burns: its heat breathing like coals, a thin wisp of light
## smoke from the grille and a quiet fire crackle (the owner's addition: Factorio's own burner inserter
## has no fire, light or smoke). It burns when its glow is lit: while inserter_arms.gd draws its hand
## moving (anim.gd arm_moving, L4). Only models whose burner inserter glows (prepare()); the built-in
## packs' have no glowing part and stay as they were.
##
## - The heat: the glowing material's glow_heat (factorio_material.gdshaderinc), the shader's own noise
##   on its clock, each instance out of phase by where it stands; no CPU work per inserter.
## - The smoke: one wisp every few seconds from the grille's top, as Factorio's light-smoke (the same
##   smoke sheet as the machines' chimneys, sprite_fx.gd, its lighter and thinner colour), only within
##   SMOKE_RANGE of the listener and only while it burns.
## - The crackle: Factorio's burning-fire loop (fire-flame-on-tree's working_sound, base/sound/fire-1.ogg)
##   quietly, positional through sfx.gd's loops (its distance and mixing rules), at most MAX_SOUNDS at once.
##
## fx.gd runs it in the world (scan with the machines, wisps each frame); the Model packs window's
## preview (model_preview.gd) with one burner of its own. --burner-fx=off: none of it, as before.

## The prototypes whose glowing models burn (file names, "@pack" and a direction's suffix off).
const MODELS := ["burner-inserter"]
## glow_heat on the burner's glowing material: 1 is 0.75 to 1.15 of its glow (the shader's sum).
const HEAT := 1.0
## Where the wisp leaves, model space (tiles, north-facing): the top of Vasillo's grille. Its glowing
## texels lie on vertices x -0.11..0.12, y 0.01..0.10, z -0.28..0.28 of the base (measured from its 0.2.1
## file: the emissive texture read at each vertex's UV), so just over the grille's middle.
const VENT := Vector3(0.0, 0.12, 0.0)
## Wisps a second while it burns (each burner on its own beat), how far from the listener they show.
const SMOKE_RATE := 0.4
const SMOKE_RANGE := 30.0
## Factorio's light-smoke is colour 0.5 grey at 0.3 alpha where its smoke is 0.4 at 0.4; the chimneys'
## tint (fx.gd _puff: 0.3 at 0.6 on the mid-grey sheet) taken the same way.
const SMOKE_COLOR := Color(0.375, 0.365, 0.35, 0.45)
const SMOKE_WIDTH := Vector2(0.25, 0.8)  # tiles across as it leaves, and at its end
const SMOKE_LIFE := Vector2(1.8, 2.6)  # seconds
const SMOKE_RISE := Vector2(0.35, 0.55)  # tiles a second up
const SOUND := "base/sound/fire-1.ogg"
const SOUND_VOLUME := 0.3
## Half the default audible distance: heard close by, as a small fire.
const SOUND_REACH := 0.5
const MAX_SOUNDS := 3
const SOUND_GROUP := "burner-inserter-fire"

static var on := true
static var _read_args := false
## The meshes whose burner burns (prepare()), each its vent.
static var _burners := {}


static func enabled() -> bool:
	if not _read_args:
		_read_args = true
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--burner-fx="):
				on = arg.get_slice("=", 1) != "off"
	return on


## A model just made (model_library.gd _make): a burner inserter's glowing, unmerged materials get the
## coals' heat, and the mesh is noted as burning. Nothing for other models, or a burner inserter
## without a glowing part.
static func prepare(mesh: Mesh, file: String) -> void:
	if mesh == null or not enabled() or not _is_burner(file):
		return
	var found := false
	for i in mesh.get_surface_count():
		var m := mesh.surface_get_material(i) as ShaderMaterial
		if m == null or m.get_shader_parameter("activity_glow") != true:
			continue
		var rows: Variant = m.get_shader_parameter("material_rows")
		if rows != null and int(rows) > 0:
			continue  # a merged material's rows have no heat of their own
		m.set_shader_parameter("glow_heat", HEAT)
		found = true
	if found:
		_burners[mesh] = VENT


static func _is_burner(file: String) -> bool:
	var base := file.get_slice("@", 0)
	for side in ["-north", "-east", "-south", "-west"]:
		base = base.trim_suffix(side)
	return MODELS.has(base)


## Whether a mesh is a burning burner's (prepare() found its glow).
static func burns(mesh: Mesh) -> bool:
	return mesh != null and _burners.has(mesh)


static func any() -> bool:
	return not _burners.is_empty()


## The glow's share at time t for an instance's seed: the shader's sum (glow_heat), for tests and probes.
static func heat_wave(t: float, seed: float, heat := HEAT) -> float:
	var ht := (t + seed * 37.0) * TAU
	var n := 0.5 * sin(ht * 0.9) + 0.3 * sin(ht * 1.7 + 1.3) + 0.2 * sin(ht * 2.9 + 2.9)
	return 1.0 + heat * (-0.05 + 0.2 * n)


## One wisp at `at` (world or preview space) on `sprites` (sprite_fx.gd, or anything with its emit()).
## `wind` drifts it as the world's smoke drifts.
static func wisp(sprites: Object, at: Vector3, wind := Vector3.ZERO) -> void:
	if sprites == null:
		return
	var c: Variant = sprites.call("emit", "smoke", at, SMOKE_WIDTH.x, randf_range(SMOKE_LIFE.x, SMOKE_LIFE.y), SMOKE_COLOR)
	if c == null:
		return
	c.size1 = SMOKE_WIDTH.y * randf_range(0.85, 1.15)
	c.vel = Vector3(randf_range(-0.06, 0.06), randf_range(SMOKE_RISE.x, SMOKE_RISE.y), randf_range(-0.06, 0.06)) + wind * 0.6
	c.rise = 0.03
	c.drag = 0.2
	c.spin_rate = randf_range(-0.3, 0.3)


## Where an entity's wisp leaves in the world: its vent turned with it (yaw), on the ground under it.
static func vent_at(pos: Vector2, yaw: float, ground := 0.0) -> Vector3:
	return Vector3(pos.x, ground, pos.y) + VENT.rotated(Vector3.UP, yaw)


# --- The world's burners (fx.gd) ------------------------------------------------------------------

## Burning burners near the listener (scan()): unit -> [vent, seconds to the next wisp].
var burning := {}
## Wisps made (tests and probes).
var wisps := 0


## Every SCAN_INTERVAL (fx.gd _scan): the inserters whose hand moves (anim.gd arm_working) within
## SMOKE_RANGE whose model burns (`mesh_of(rec)` its drawn mesh) are the burning ones; their crackles,
## the nearest MAX_SOUNDS within `hearing`, are added to `sources` (sfx.gd set_loops' form). `vent_of(rec)`
## gives a burner's vent in the world.
func scan(entities: Dictionary, working: Dictionary, focus: Vector2, hearing: float, sources: Array,
		mesh_of: Callable, vent_of: Callable) -> void:
	var now := {}
	if not enabled() or not any():
		burning = now
		return
	var heard: Array = []
	for unit in working:
		var rec = entities.get(unit)
		if rec == null:
			continue
		var d: float = (rec.pos as Vector2).distance_to(focus)
		if d > SMOKE_RANGE or not burns(mesh_of.call(rec)):
			continue
		var was: Array = burning.get(unit, [])
		var vent: Vector3 = vent_of.call(rec)
		now[unit] = [vent, float(was[1]) if was.size() > 1 else randf() / SMOKE_RATE]
		if d < hearing:
			heard.append([d, unit, vent])
	burning = now
	heard.sort_custom(func(a, b): return a[0] < b[0])
	for k in mini(heard.size(), MAX_SOUNDS):
		sources.append(crackle_source("burner%d" % int(heard[k][1]), heard[k][2]))


## A crackle loop at `at`, in sfx.gd set_loops' form.
static func crackle_source(key: Variant, at: Vector3) -> Dictionary:
	return {"key": key, "pos": at, "path": SOUND, "volume": SOUND_VOLUME, "reach": SOUND_REACH,
		"group": SOUND_GROUP, "per_group": MAX_SOUNDS, "fade_in": 0.3, "fade_out": 0.5}


## Each frame: the burning burners' wisps, each at SMOKE_RATE.
func step(sprites: Object, delta: float, wind := Vector3.ZERO) -> void:
	for unit in burning:
		var b: Array = burning[unit]
		var due := float(b[1]) - delta
		while due <= 0.0:
			due += 1.0 / SMOKE_RATE * randf_range(0.7, 1.3)
			wisp(sprites, b[0], wind)
			wisps += 1
		b[1] = due


func clear() -> void:
	burning.clear()
