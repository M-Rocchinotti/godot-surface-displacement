@tool
extends EditorPlugin
## Editor-side test, run by tests/run_editor_check.py inside a throwaway project: exercises the
## GADS plugin's Tools actions (including making and baking a GADSMeshInstance3D) and their
## undo/redo in a real editor, checks what
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
	_sd_plugin = load("res://addons/gads/plugin.gd").new()
	var manager := EditorInterface.get_editor_undo_redo()
	var ur := manager.get_history_undo_redo(manager.get_object_history_id(root))
	var project_text := FileAccess.get_file_as_string("res://project.godot")
	_check(project_text.contains("gads_pom_steps=") and project_text.contains("gads_dfg="), "the plugin registered its shader globals in project.godot")

	# 1. GADSManager node, undo, redo.
	_sd_plugin.add_manager_node()
	_check(root.find_children("*", "GADSManager", true, false).size() == 1, "Add GADSManager Node adds one")
	ur.undo()
	_check(root.find_children("*", "GADSManager", true, false).is_empty(), "undo removes it")
	ur.redo()
	_check(root.find_children("*", "GADSManager", true, false).size() == 1, "redo adds it back")

	# 2. Field for the selected ground.
	var ground := root.get_node("Ground") as MeshInstance3D
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(ground)
	_sd_plugin.add_field_for_selection()
	var fields := root.find_children("*", "GADSDisplacementField3D", true, false)
	var field := fields[0] as GADSDisplacementField3D if fields.size() == 1 else null
	_check(field != null and field.layers.size() == 1 and field.layers[0] == ground.material_override and ground.is_in_group(&"gads_ground"),
			"Add GADSDisplacementField3D uses the selected ground's material as its layer and puts the ground in the group")
	ur.undo()
	_check(root.find_children("*", "GADSDisplacementField3D", true, false).is_empty() and not ground.is_in_group(&"gads_ground"), "undo removes the field and the group")
	ur.redo()
	field = root.find_children("*", "GADSDisplacementField3D", true, false)[0] as GADSDisplacementField3D

	# 3. Material conversion.
	var box := root.get_node("HeightBox") as MeshInstance3D
	var glass := root.get_node("GlassBox") as MeshInstance3D
	var csg := root.get_node("HeightCSG") as GeometryInstance3D
	var old := box.material_override
	var old_csg := csg.get("material") as Material
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(box)
	EditorInterface.get_selection().add_node(glass)
	EditorInterface.get_selection().add_node(csg)
	_sd_plugin.convert_selection()
	var info := GADSMaterials.parse((box.material_override as ShaderMaterial).shader) if box.material_override is ShaderMaterial else {}
	_check(not info.is_empty() and info["mapping"] == GADSMaterials.Mapping.UV and glass.material_override is StandardMaterial3D,
			"Convert Materials turns the height-map material into a UV-mapped GADS material and skips the transparent one")
	_check(GADSMaterials.is_gads_material(csg.get("material")), "it converts a CSG shape's material too")
	ur.undo()
	_check(box.material_override == old and csg.get("material") == old_csg, "undo restores the original materials")
	ur.redo()
	_check(box.material_override is ShaderMaterial and GADSMaterials.is_gads_material(csg.get("material")), "redo converts again")

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
	# A second bake while the first is still assigned (the resource cache holds the old one).
	ground.position.y = 0.5
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(field)
	await _sd_plugin.bake_selected_field()
	_check(field.ground_bake != null and absf(field.ground_bake.sample_height(Vector2(1.0, -2.0)) - 0.5) < 0.001
			and field.ground_bake.resource_path == "res://check_scene_ground.res",
			"baking again gives the field the new ground, still from the saved file")
	# Undo and redo of the re-bake must leave a bake that is saved as a reference, not embedded.
	ur.undo()
	ur.redo()
	ground.position.y = 0.0

	# 5. Validation.
	var issues := GADSValidator.validate(root)
	var errors := issues.filter(func(i: Dictionary) -> bool: return i["level"] == "error")
	_check(errors.is_empty(), "Validate Setup finds no errors (%d issues)" % issues.size())

	# 6. Height-map preparation.
	var stats := GADSHeightTools.convert_to_half_exr("res://height_source.png", "res://height_source_gads_height.exr")
	_check(not stats.is_empty() and FileAccess.file_exists("res://height_source_gads_height.exr") and FileAccess.file_exists("res://height_source_gads_height.exr.import"),
			"Prepare Height Maps writes a 16-bit EXR with its import settings (source levels: %d)" % stats.get("levels", 0))
	var exr := Image.load_from_file(ProjectSettings.globalize_path("res://height_source_gads_height.exr"))
	_check(exr != null and exr.get_format() == Image.FORMAT_RH and absf(exr.get_pixel(31, 0).r - 1.0) < 0.01 and absf(exr.get_pixel(0, 0).r) < 0.01,
			"it is one half-float channel, remapped to 0-1")

	# 7. Baked displacement: make the converted box a GADSMeshInstance3D, bake it, undo and redo.
	var box_mesh := box.mesh
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(box)
	_sd_plugin.convert_selected_meshes()
	var baked_box := root.get_node("HeightBox") as GADSMeshInstance3D
	_check(baked_box != null and baked_box.source_mesh == box_mesh and baked_box.mesh == box_mesh and not baked_box.baked,
			"Make Selected Meshes GADSMeshInstance3D keeps the mesh as the source")
	ur.undo()
	_check(not root.get_node("HeightBox") is GADSMeshInstance3D and box.mesh == box_mesh, "undo makes it a plain MeshInstance3D again")
	ur.redo()
	baked_box = root.get_node("HeightBox") as GADSMeshInstance3D
	EditorInterface.edit_node(baked_box)
	await _frames_wait(5)
	var buttons := EditorInterface.get_inspector().find_children("*", "Button", true, false).filter(
			func(b: Button) -> bool: return b.text in ["Bake", "Rebuild", "Clear"])
	_check(buttons.size() == 3, "the inspector shows Bake, Rebuild and Clear")
	_sd_plugin.bake_selected_meshes()
	var baked_path: String = baked_box.bake_stats.get("path", "") if baked_box != null else ""
	_check(baked_box != null and baked_box.baked and baked_path.begins_with("res://gads_baked/") and FileAccess.file_exists(baked_path)
			and baked_box.mesh.resource_path == baked_path and baked_box.bake_stats.get("triangles", 0) > 12,
			"Bake Selected GADSMeshInstance3D bakes it into res://gads_baked/ (%d triangles)" % (baked_box.bake_stats.get("triangles", 0) if baked_box != null else 0))
	ur.undo()
	_check(not baked_box.baked and baked_box.mesh == box_mesh, "undo shows the source mesh again")
	ur.redo()
	_check(baked_box.baked and baked_box.mesh.resource_path == baked_path, "redo shows the bake again")
	EditorInterface.get_selection().clear()

	# 8. The GADS bottom panel profiles the scene.
	var panels := EditorInterface.get_base_control().find_children("GADS", "VBoxContainer", true, false).filter(
			func(n: Node) -> bool: return n.has_method("refresh_report"))
	_check(panels.size() == 1, "the GADS bottom panel is there")
	if panels.size() == 1:
		panels[0].refresh_report()
		var report: Dictionary = panels[0].get_report()
		_check(report.get("totals", {}).get("objects", 0) == 1 and report.get("surfaces", 0) >= 2,
				"it lists the baked box and the parallax surfaces (%s)" % report.get("totals", {}))

	# 9. What a save writes.
	EditorInterface.save_scene()
	await _frames_wait(5)
	var text := FileAccess.get_file_as_string("res://check_scene.tscn")
	_check(text.contains('path="%s"' % baked_path) and text.contains("source_mesh") and text.contains("instance_shader_parameters/gads_baked = 1.0"),
			"the baked box refers to its bake file, keeps its source mesh and the baked flag")
	_check(not text.contains("FieldMesh") and not text.contains("Pebbles"), "the field's internal mesh is not saved with the scene")
	_check(text.contains("gads_world_pom_ss.gdshader"), "the editor does not switch the saved material's variant")
	# The node's default preset (Medium) has no near-camera geometry; in the editor that must not
	# hide the field or change its saved properties.
	_check(field.visible and not text.contains("visible = false") and not text.contains("resolution = "),
			"the GADSManager node leaves the field's saved properties alone in the editor")
	_check(text.contains("check_scene_ground.res") and not text.contains("gads_ground_bake.gd"), "the field keeps its bake as a reference to the file (nothing embedded)")
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
