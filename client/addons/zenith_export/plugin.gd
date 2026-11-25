@tool
extends EditorPlugin
## Adds Zenith's export plugins (models_export.gd and shader_hash_export.gd) to every export (tools/release/package.py).

const ModelsExport := preload("res://addons/zenith_export/models_export.gd")
const ShaderHashExport := preload("res://addons/zenith_export/shader_hash_export.gd")

var _export: EditorExportPlugin
var _shader_hash: EditorExportPlugin


func _enter_tree() -> void:
	_export = ModelsExport.new()
	add_export_plugin(_export)
	_shader_hash = ShaderHashExport.new()
	add_export_plugin(_shader_hash)


func _exit_tree() -> void:
	if _export != null:
		remove_export_plugin(_export)
		_export = null
	if _shader_hash != null:
		remove_export_plugin(_shader_hash)
		_shader_hash = null
