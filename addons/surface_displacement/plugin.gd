@tool
extends EditorPlugin
## Surface Displacement editor integration: registers the shader globals the materials read.


func _enable_plugin() -> void:
	SDGlobals.ensure_registered(true)


func _enter_tree() -> void:
	SDGlobals.ensure_registered(true)
