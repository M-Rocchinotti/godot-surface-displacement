@tool
extends EditorExportPlugin
## Exports the bakes that streamed GADSMeshInstance3D nodes load by path (see
## [member GADSMeshInstance3D.stream_bake]): a scene does not list them among its dependencies, so
## an export of selected scenes and their dependencies would leave them out. Each cache file goes
## into the export once.

var _in_export := {} # cache files in this export so far: path -> true


func _get_name() -> String:
	return "GADS"


func _export_begin(_features: PackedStringArray, _is_debug: bool, _path: String, _flags: int) -> void:
	_in_export = {}


func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if GADSBakeCache.is_cache_file(path):
		if _in_export.has(path):
			skip() # already added with a scene that streams it
		_in_export[path] = true
		return
	if not path.get_extension() in GADSBakeCache.SCENE_EXTENSIONS:
		return
	for bake in GADSBakeCache.paths_in_file(path):
		if not _in_export.has(bake) and FileAccess.file_exists(bake):
			_in_export[bake] = true
			add_file(bake, FileAccess.get_file_as_bytes(bake), false)


## The cache files this export holds so far (for tools and tests).
func get_exported_bakes() -> PackedStringArray:
	return PackedStringArray(_in_export.keys())
