@tool
class_name GADSTerrainEdit
extends RefCounted
## Runs an edit of a GADSTerrain3D (a road, Generate, Erode...) as one undoable action in the
## editor: the heightmap and / or splat map before and after, and, when the edit made a map
## editable, the original map back on undo; the edited maps are saved after it, its undo and redo.
## Outside the editor it just runs the edit.

## [param edit] changes [param terrain]'s heights ([param heights]) and / or layers
## ([param splat]) when called. [param undo]: an EditorUndoRedoManager (default: the editor's).
static func run(terrain: GADSTerrain3D, action_name: String, edit: Callable, heights := true, splat := false, undo: Object = null) -> void:
	if undo == null and Engine.is_editor_hint() and Engine.has_singleton(&"EditorInterface"):
		undo = Engine.get_singleton(&"EditorInterface").call(&"get_editor_undo_redo")
	if undo == null:
		edit.call()
		return
	# [property, region setter, was editable, original map, before]; the first three are read
	# before the image (reading it makes the map editable).
	var maps := []
	if heights:
		maps.append(["heightmap", "set_height_region", terrain.is_height_editable(), terrain.heightmap, terrain.get_height_image()])
	if splat:
		maps.append(["splatmap", "set_splat_region", terrain.is_splat_editable(), terrain.splatmap, terrain.get_splat_image()])
	edit.call()
	terrain.flush_edits()
	undo.call(&"create_action", action_name, UndoRedo.MERGE_DISABLE, terrain)
	for m: Array in maps:
		var after: Image = terrain.get_height_image() if m[0] == "heightmap" else terrain.get_splat_image()
		if not m[2]:
			undo.call(&"add_do_property", terrain, m[0], terrain.get(m[0]))
		undo.call(&"add_do_method", terrain, m[1], Vector2i.ZERO, after)
	undo.call(&"add_do_method", terrain, &"save_edited_maps")
	for m: Array in maps:
		undo.call(&"add_undo_method", terrain, m[1], Vector2i.ZERO, m[4])
		if not m[2]:
			undo.call(&"add_undo_property", terrain, m[0], m[3])
	undo.call(&"add_undo_method", terrain, &"save_edited_maps")
	undo.call(&"commit_action", false)
	terrain.save_edited_maps()
