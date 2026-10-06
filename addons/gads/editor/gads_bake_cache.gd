@tool
class_name GADSBakeCache
extends RefCounted
## The files in GADS bake caches that nothing uses any more. Every bake of a GADSMeshInstance3D is
## saved as [code]<cache_directory>/<name>_<key>.mesh[/code] (and [code]_collision.res[/code]),
## named after its inputs, so changing a material, the quality or the mesh leaves the earlier bake
## behind. A cache file is in use when a scene or resource of the project refers to it (its
## dependencies, as the editor's own Owners dialog finds them) or something holds it in memory
## (an open scene, the undo history). Only files named like GADS cache files are ever listed; a
## bake that only a script loads by its path counts as unused.
## [codeblock]
## var unused := GADSBakeCache.find_unused()
## GADSBakeCache.remove(unused)     # to the system trash where there is one
## [/codeblock]

const DEFAULT_DIRECTORY := "res://gads_baked"
## Files that can refer to a bake.
const REFERRING_EXTENSIONS := ["tscn", "scn", "tres", "res"]

static var _name_pattern: RegEx


## Whether [param path] is named like a GADS cache file: a bake ([code]<name>_<16 hex>.mesh[/code]),
## its collision shape ([code]<name>_<16 hex>_collision.res[/code]) or a sculpt map
## ([code]<name>_sculpt.res[/code]).
static func is_cache_file(path: String) -> bool:
	if _name_pattern == null:
		_name_pattern = RegEx.create_from_string("^.+_([0-9a-f]{16}(_collision\\.res|\\.mesh)|sculpt\\.res)$")
	return _name_pattern.search(path.get_file()) != null


## The cache files no scene or resource of the project refers to and nothing holds in memory, in
## [param directories], the default cache directory and every directory a project file has a cache
## file in. Sorted.
static func find_unused(directories: PackedStringArray = PackedStringArray()) -> PackedStringArray:
	var referenced := {}
	var cache_dirs := {DEFAULT_DIRECTORY: true}
	for d in directories:
		cache_dirs[d.trim_suffix("/")] = true
	for file in _project_files("res://"):
		if not file.get_extension() in REFERRING_EXTENSIONS or is_cache_file(file):
			continue
		for dep in ResourceLoader.get_dependencies(file):
			var path := dependency_path(dep)
			if path.is_empty():
				continue
			referenced[path] = true
			if is_cache_file(path):
				cache_dirs[path.get_base_dir()] = true
	var unused := PackedStringArray()
	for dir: String in cache_dirs:
		if not DirAccess.dir_exists_absolute(dir):
			continue
		for f in DirAccess.get_files_at(dir):
			var path := dir.path_join(f)
			if is_cache_file(path) and not referenced.has(path) and not ResourceLoader.has_cached(path):
				unused.append(path)
	unused.sort()
	return unused


## The path in one entry of [method ResourceLoader.get_dependencies] ("uid::type::path", or a
## plain path), through its UID when the path is missing.
static func dependency_path(entry: String) -> String:
	var uid := ""
	for part in entry.split("::"):
		if part.begins_with("res://") or part.begins_with("user://"):
			return part
		if part.begins_with("uid://"):
			uid = part
	if not uid.is_empty():
		var id := ResourceUID.text_to_id(uid)
		if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id):
			return ResourceUID.get_id_path(id)
	return ""


## Total size in bytes of [param paths].
static func total_size(paths: PackedStringArray) -> int:
	var bytes := 0
	for p in paths:
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			bytes += f.get_length()
	return bytes


## Moves [param paths] to the system trash (deletes them where there is none). Returns how many
## are gone.
static func remove(paths: PackedStringArray) -> int:
	var removed := 0
	for p in paths:
		var global := ProjectSettings.globalize_path(p)
		if not FileAccess.file_exists(p):
			continue
		if OS.move_to_trash(global) != OK and DirAccess.remove_absolute(global) != OK:
			push_warning("GADS: cannot remove %s." % p)
			continue
		removed += 1
	return removed


static func _project_files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	if FileAccess.file_exists(dir.path_join(".gdignore")):
		return out
	for f in DirAccess.get_files_at(dir):
		out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if d.begins_with("."):
			continue
		out.append_array(_project_files(dir.path_join(d)))
	return out
