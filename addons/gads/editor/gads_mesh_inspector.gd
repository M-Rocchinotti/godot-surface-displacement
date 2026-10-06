@tool
extends EditorInspectorPlugin
## Bake / Rebuild / Clear / Diagnose / Export buttons, progress and statistics at the top of a
## GADSMeshInstance3D's inspector. A finished bake and Clear are undoable.

var undo_redo: EditorUndoRedoManager


func _can_handle(object: Object) -> bool:
	return object is GADSMeshInstance3D


func _parse_begin(object: Object) -> void:
	var panel := BakePanel.new()
	panel.node = object as GADSMeshInstance3D
	panel.undo_redo = undo_redo
	add_custom_control(panel)


class BakePanel extends VBoxContainer:
	var node: GADSMeshInstance3D
	var undo_redo: EditorUndoRedoManager
	var _bake: Button
	var _rebuild: Button
	var _clear: Button
	var _cancel: Button
	var _diagnose: Button
	var _export: Button
	var _diagnosis: Label
	var _progress: ProgressBar
	var _status: Label
	var _before := {}

	func _ready() -> void:
		var row := HBoxContainer.new()
		add_child(row)
		_bake = _button(row, "Bake", "Bake the relief into the mesh (reuses a cached bake of the same inputs).", _on_bake.bind(false))
		_rebuild = _button(row, "Rebuild", "Bake again, ignoring the cache.", _on_bake.bind(true))
		_clear = _button(row, "Clear", "Show the source mesh again.", _on_clear)
		_cancel = _button(row, "Cancel", "Stop the running bake.", _on_cancel)
		_diagnose = _button(row, "Diagnose", "Show the source mesh's open, non-manifold, UV-seam, hard and surface-border edges.", _on_diagnose)
		_diagnose.toggle_mode = true
		_diagnose.button_pressed = node.is_diagnostics_visible()
		_export = _button(row, "Export", "Write the baked mesh to a .glb, .gltf or .obj file for other tools.", _on_export)
		_progress = ProgressBar.new()
		_progress.max_value = 1.0
		_progress.step = 0.001
		add_child(_progress)
		_status = Label.new()
		_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_status.add_theme_font_size_override("font_size", 12)
		add_child(_status)
		_diagnosis = Label.new()
		_diagnosis.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_diagnosis.add_theme_font_size_override("font_size", 12)
		_diagnosis.visible = false
		add_child(_diagnosis)
		node.bake_progress.connect(_on_progress)
		node.bake_finished.connect(_on_finished)
		_refresh()

	func _exit_tree() -> void:
		if is_instance_valid(node):
			if node.bake_progress.is_connected(_on_progress):
				node.bake_progress.disconnect(_on_progress)
			if node.bake_finished.is_connected(_on_finished):
				node.bake_finished.disconnect(_on_finished)

	func _button(row: HBoxContainer, text: String, tip: String, action: Callable) -> Button:
		var b := Button.new()
		b.text = text
		b.tooltip_text = tip
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(action)
		row.add_child(b)
		return b

	func _on_bake(force: bool) -> void:
		_before = node.get_bake_state()
		if node.bake_async(force) == OK:
			_refresh()

	func _on_cancel() -> void:
		node.cancel_bake()

	## Toggles the edge overlay; the summary names the colours.
	func _on_diagnose() -> void:
		node.set_diagnostics_visible(_diagnose.button_pressed)
		_diagnosis.visible = _diagnose.button_pressed
		if _diagnose.button_pressed:
			_diagnosis.text = GADSMeshDiagnostics.summary(node.diagnose()) + "\nOverlay: open red, non-manifold magenta, UV seams yellow, hard edges cyan, surface borders green."

	func _on_export() -> void:
		var dialog := EditorFileDialog.new()
		dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		dialog.title = "Export Baked Mesh"
		dialog.filters = PackedStringArray(["*.glb ; glTF binary", "*.gltf ; glTF", "*.obj ; Wavefront OBJ"])
		dialog.current_file = String(node.name).to_snake_case() + ".glb"
		dialog.file_selected.connect(func(path: String) -> void:
			var err := node.export_baked(path)
			_status.text = ("Exported to %s." % path) if err == OK else ("Export failed: %s." % error_string(err))
			dialog.queue_free())
		dialog.canceled.connect(dialog.queue_free)
		EditorInterface.get_base_control().add_child(dialog)
		dialog.popup_file_dialog()

	func _on_clear() -> void:
		var before := node.get_bake_state()
		undo_redo.create_action("Clear GADS bake", UndoRedo.MERGE_DISABLE, node)
		undo_redo.add_do_method(node, "clear_bake")
		undo_redo.add_undo_method(node, "set_bake_state", before)
		undo_redo.commit_action()
		_refresh()

	func _on_progress(progress: float, triangles: int) -> void:
		_progress.value = progress
		_status.text = "Baking: %d triangles" % triangles

	func _on_finished(ok: bool) -> void:
		if ok and not _before.is_empty():
			# Already applied by the node; recorded so it can be undone.
			undo_redo.create_action("Bake GADS mesh", UndoRedo.MERGE_DISABLE, node)
			undo_redo.add_do_method(node, "set_bake_state", node.get_bake_state())
			undo_redo.add_undo_method(node, "set_bake_state", _before)
			undo_redo.commit_action(false)
		_before = {}
		_refresh()

	func _refresh() -> void:
		var busy := node.is_baking()
		var available := GADSMeshBaker.is_available()
		_bake.disabled = busy or not available
		_rebuild.disabled = busy or not available
		_clear.disabled = busy or not node.baked
		_export.disabled = busy or not node.baked
		_cancel.visible = busy
		_progress.visible = busy
		if busy:
			_progress.value = 0.0
			_status.text = "Baking..."
		elif not available:
			_status.text = "The GADS native library is not loaded on this platform."
		elif not node.baked:
			_status.text = "Not baked: drawing the source mesh with the materials' parallax."
		else:
			_status.text = node.get_bake_summary()

