extends MeshInstance3D
## The debug menu's chunk borders (debug_menu.gd): lines along Factorio's 32-tile chunk edges round
## the world's focus, drawn over everything (hills too), yellow for chunks the client has loaded and
## grey for the rest. One ImmediateMesh, made again only when the focus moves to another chunk or
## the loaded chunks change.

const CHUNK := 32.0
const RINGS := 6  # chunks each way from the focus chunk
const LIFT := 0.08

var world  # world.gd

var _key := []


func _ready() -> void:
	mesh = ImmediateMesh.new()
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.no_depth_test = true
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.render_priority = 10
	material_override = m


func _process(_delta: float) -> void:
	if world == null:
		return
	var c: Vector2i = world.chunk_of(world.focus())
	var key := [c, world.loaded_chunk_count()]
	if key == _key:
		return
	_key = key
	var im := mesh as ImmediateMesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for dy in range(-RINGS, RINGS + 1):
		for dx in range(-RINGS, RINGS + 1):
			var at := c + Vector2i(dx, dy)
			var cv = world.chunks.get(at)
			var col := Color(1.0, 0.85, 0.2, 0.85) if cv != null and cv.loaded else Color(0.7, 0.7, 0.7, 0.5)
			var x0 := at.x * CHUNK
			var z0 := at.y * CHUNK
			# The north and west edges of each chunk; the last row and column close the grid.
			_line(im, col, Vector3(x0, LIFT, z0), Vector3(x0 + CHUNK, LIFT, z0))
			_line(im, col, Vector3(x0, LIFT, z0), Vector3(x0, LIFT, z0 + CHUNK))
			if dy == RINGS:
				_line(im, col, Vector3(x0, LIFT, z0 + CHUNK), Vector3(x0 + CHUNK, LIFT, z0 + CHUNK))
			if dx == RINGS:
				_line(im, col, Vector3(x0 + CHUNK, LIFT, z0), Vector3(x0 + CHUNK, LIFT, z0 + CHUNK))
	im.surface_end()


static func _line(im: ImmediateMesh, col: Color, a: Vector3, b: Vector3) -> void:
	im.surface_set_color(col)
	im.surface_add_vertex(a)
	im.surface_set_color(col)
	im.surface_add_vertex(b)
