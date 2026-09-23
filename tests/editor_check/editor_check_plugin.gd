@tool
extends EditorPlugin
## Editor-side test, run by tests/run_editor_check.py inside a throwaway project: exercises the
## Surface Displacement plugin's Tools actions and their undo/redo in a real editor, checks what
## a save writes, prints "EDITOR CHECK OK" or "EDITOR CHECK FAIL", then quits the editor.

var _frames := 0
var _failures: PackedStringArray = []
var _sd_plugin: EditorPlugin
var _busy := false


func _enter_tree() -> void:
	set_process(true)


func _process(_delta: float) -> void:
	if _busy:
		return
	_frames += 1
	if _frames == 30:
		EditorInterface.open_scene_from_path("res://check_scene.tscn")
	elif _frames == 60:
		_busy = true
		await _run()
		_busy = false


func _check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		_failures.append(what)


func _frames_wait(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _run() -> void:
	var root := EditorInterface.get_edited_scene_root()
	_check(root != null and root.name == "CheckScene", "test scene is open")
	if root == null:
		_finish()
		return
	_sd_plugin = load("res://addons/surface_displacement/plugin.gd").new()
	var manager := EditorInterface.get_editor_undo_redo()
	var ur := manager.get_history_undo_redo(manager.get_object_history_id(root))
	var project_text := FileAccess.get_file_as_string("res://project.godot")
	_check(project_text.contains("sd_pom_steps=") and project_text.contains("sd_dfg="), "the plugin registered its shader globals in project.godot")

	# 1. SurfaceDisplacement node, undo, redo.
	_sd_plugin.add_manager_node()
	_check(root.find_children("*", "SurfaceDisplacement", true, false).size() == 1, "Add SurfaceDisplacement Node adds one")
	ur.undo()
	_check(root.find_children("*", "SurfaceDisplacement", true, false).is_empty(), "undo removes it")
	ur.redo()
	_check(root.find_children("*", "SurfaceDisplacement", true, false).size() == 1, "redo adds it back")

	# 2. Field for the selected ground.
	var ground := root.get_node("Ground") as MeshInstance3D
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(ground)
	_sd_plugin.add_field_for_selection()
	var fields := root.find_children("*", "DisplacementField3D", true, false)
	var field := fields[0] as DisplacementField3D if fields.size() == 1 else null
	_check(field != null and field.layers.size() == 1 and field.layers[0] == ground.material_override and ground.is_in_group(&"sd_ground"),
			"Add DisplacementField3D uses the selected ground's material as its layer and puts the ground in the group")
	ur.undo()
	_check(root.find_children("*", "DisplacementField3D", true, false).is_empty() and not ground.is_in_group(&"sd_ground"), "undo removes the field and the group")
	ur.redo()
	field = root.find_children("*", "DisplacementField3D", true, false)[0] as DisplacementField3D

	# 3. Material conversion.
	var box := root.get_node("HeightBox") as MeshInstance3D
	var glass := root.get_node("GlassBox") as MeshInstance3D
	var old := box.material_override
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(box)
	EditorInterface.get_selection().add_node(glass)
	_sd_plugin.convert_selection()
	var info := SDMaterials.parse((box.material_override as ShaderMaterial).shader) if box.material_override is ShaderMaterial else {}
	_check(not info.is_empty() and info["mapping"] == SDMaterials.Mapping.UV and glass.material_override is StandardMaterial3D,
			"Convert Materials turns the height-map material into a UV-mapped SD material and skips the transparent one")
	ur.undo()
	_check(box.material_override == old, "undo restores the original material")
	ur.redo()
	_check(box.material_override is ShaderMaterial, "redo converts again")

	# 4. Ground bake (renders in the editor).
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(field)
	await _sd_plugin.bake_selected_field()
	_check(field.ground_bake != null and FileAccess.file_exists("res://check_scene_ground.res"), "Bake Ground saves the bake next to the scene and assigns it")
	if field.ground_bake != null:
		_check(absf(field.ground_bake.sample_height(Vector2(1.0, -2.0))) < 0.001 and field.ground_bake.sample_weights(Vector2(1.0, -2.0)).r > 0.99,
				"the baked ground is at y = 0 and carries the ground's layer")
	ur.undo()
	_check(field.ground_bake == null, "undo removes the bake from the field")
	ur.redo()

	# 5. Validation.
	var issues := SDValidator.validate(root)
	var errors := issues.filter(func(i: Dictionary) -> bool: return i["level"] == "error")
	_check(errors.is_empty(), "Validate Setup finds no errors (%d issues)" % issues.size())

	# 6. Height-map preparation.
	var stats := SDHeightTools.convert_to_half_exr("res://height_source.png", "res://height_source_sd_height.exr")
	_check(not stats.is_empty() and FileAccess.file_exists("res://height_source_sd_height.exr") and FileAccess.file_exists("res://height_source_sd_height.exr.import"),
			"Prepare Height Maps writes a 16-bit EXR with its import settings (source levels: %d)" % stats.get("levels", 0))
	var exr := Image.load_from_file(ProjectSettings.globalize_path("res://height_source_sd_height.exr"))
	_check(exr != null and exr.get_format() == Image.FORMAT_RH and absf(exr.get_pixel(31, 0).r - 1.0) < 0.01 and absf(exr.get_pixel(0, 0).r) < 0.01,
			"it is one half-float channel, remapped to 0-1")

	# 7. What a save writes.
	EditorInterface.save_scene()
	await _frames_wait(5)
	var text := FileAccess.get_file_as_string("res://check_scene.tscn")
	_check(not text.contains("FieldMesh") and not text.contains("Pebbles"), "the field's internal mesh is not saved with the scene")
	_check(text.contains("sd_world_pom_ss.gdshader"), "the editor does not switch the saved material's variant")
	_check(text.contains("check_scene_ground.res"), "the field keeps its bake reference")
	_finish()


func _finish() -> void:
	print("EDITOR CHECK OK" if _failures.is_empty() else "EDITOR CHECK FAIL: %s" % ", ".join(_failures))
	if _sd_plugin != null:
		_sd_plugin.free()
	# Quitting while the field is still selected, right after undoing and redoing its bake, makes
	# the 4.7.2 editor report "Can't use get_node() with absolute paths from outside the active
	# scene tree" during shutdown (after the scene was saved; nothing is lost). The cause was not
	# found; with the selection cleared first it does not happen (README, Troubleshooting).
	EditorInterface.get_selection().clear()
	await _frames_wait(10)
	get_tree().quit(0 if _failures.is_empty() else 1)
