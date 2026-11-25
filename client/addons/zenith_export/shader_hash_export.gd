@tool
extends EditorExportPlugin
## Embeds res://data/shader_stamp.txt into exported builds with the exact MD5 computed by
## ShaderRefresh.source_shader_hash(), so exported clients invalidate GPU caches on shader
## changes rather than on every executable rebuild.

const ShaderRefresh := preload("res://scripts/menu/shader_refresh.gd")


func _get_name() -> String:
	return "ZenithShaderHash"


## Computes the deterministic MD5 hash over sorted res://**/*.gdshader and .gdshaderinc files.
static func compute_shader_hash(root: String = "res://") -> String:
	return ShaderRefresh.source_shader_hash(root)


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	var hash_str: String = compute_shader_hash("res://")
	add_file("res://data/shader_stamp.txt", hash_str.to_utf8_buffer(), false)
