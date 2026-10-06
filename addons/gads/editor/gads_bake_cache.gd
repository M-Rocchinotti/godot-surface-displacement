@tool
class_name GADSBakeCache
extends RefCounted
## The files in GADS bake caches that nothing uses any more. Every bake of a GADSMeshInstance3D is
## saved as [code]<cache_directory>/<name>_<key>.mesh[/code] (and [code]_collision.res[/code]),
## named after its inputs, so changing a material, the quality or the mesh leaves the earlier bake
## behind. A cache file is in use when a scene or resource of the project refers to it (its
## dependencies, as the editor's own Owners dialog finds them, or a path a scene stores, as a
## streamed bake's) or something holds it in memory (an open scene, the undo history). Only files
## named like GADS cache files are ever listed; a bake that only a script loads by its path counts
## as unused.
## [codeblock]
## var unused := GADSBakeCache.find_unused()
## GADSBakeCache.remove(unused)     # to the system trash where there is one
## [/codeblock]

const DEFAULT_DIRECTORY := "res://gads_baked"
## Files that can refer to a bake.
const REFERRING_EXTENSIONS := ["tscn", "scn", "tres", "res"]
## Files whose stored paths are read too (see [method paths_in_file]).
const SCENE_EXTENSIONS := ["tscn", "scn"]

static var _name_pattern: RegEx


## Whether [param path] is named like a GADS cache file: a bake ([code]<name>_<16 hex>.mesh[/code]),
## its collision shape ([code]<name>_<16 hex>_collision.res[/code]), a sculpt map
## ([code]<name>_sculpt.res[/code]) or a painted mesh ([code]<name>_painted.mesh[/code],
## [code]_painted_2.mesh[/code], ...).
static func is_cache_file(path: String) -> bool:
	if _name_pattern == null:
		_name_pattern = RegEx.create_from_string("^.+_([0-9a-f]{16}(_collision\\.res|\\.mesh)|sculpt\\.res|painted(_[0-9]+)?\\.mesh)$")
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
		for path in paths_in_file(file):
			referenced[path] = true
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


## The cache files [param file] (a scene or resource) refers to: its dependencies and, for a
## scene, the cache file paths its nodes store, such as a streamed bake's
## ([member GADSMeshInstance3D.stream_bake]), which the scene loads by path and so does not list
## among its dependencies.
static func paths_in_file(file: String) -> PackedStringArray:
	var found := {}
	for dep in ResourceLoader.get_dependencies(file):
		var path := dependency_path(dep)
		if is_cache_file(path):
			found[path] = true
	if file.get_extension() in SCENE_EXTENSIONS:
		for path in stored_paths(FileAccess.get_file_as_bytes(file)):
			if is_cache_file(path):
				found[path] = true
	return PackedStringArray(found.keys())


## The [code]res://[/code] and [code]user://[/code] paths in a saved resource's bytes (text or
## binary format: a path is stored as its UTF-8 text in both, ending at a quote or a control
## character).
static func stored_paths(bytes: PackedByteArray) -> PackedStringArray:
	var out := PackedStringArray()
	var hex := bytes.hex_encode()
	for prefix in ["res://", "user://"]:
		var needle: String = prefix.to_ascii_buffer().hex_encode()
		var at := hex.find(needle)
		while at >= 0:
			if at % 2 != 0: # not on a byte boundary
				at = hex.find(needle, at + 1)
				continue
			var start := at / 2
			var end := start
			while end < bytes.size() and bytes[end] > 0x20 and bytes[end] != 0x22 and bytes[end] != 0x7f:
				end += 1
			out.append(bytes.slice(start, end).get_string_from_utf8())
			at = hex.find(needle, end * 2)
	return out


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
