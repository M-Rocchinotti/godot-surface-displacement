@tool
extends EditorInspectorPlugin
## Bake / Rebuild / Clear / Diagnose / Export / Sculpt / Paint buttons, progress and statistics at
## the top of a GADSMeshInstance3D's inspector. A finished bake and Clear are undoable.

const PaintInspector := preload("res://addons/gads/editor/gads_paint_inspector.gd")

var undo_redo: EditorUndoRedoManager
## The plugin's fill_paint(node, channel, value).
var fill: Callable


func _can_handle(object: Object) -> bool:
	return object is GADSMeshInstance3D


func _parse_begin(object: Object) -> void:
	var panel := BakePanel.new()
	panel.node = object as GADSMeshInstance3D
	panel.undo_redo = undo_redo
	panel.fill = fill
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
	var _sculpt: Button
	var _sculpt_row: HBoxContainer
	var _paint: Button
	var _paint_row: HBoxContainer
	var fill: Callable
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
		_sculpt = _button(row, "Sculpt", "Paint the surface in the 3D viewport (left-drag): raise, lower, smooth or flatten; each stroke bakes again.", _on_sculpt)
		_sculpt.toggle_mode = true
		_sculpt.button_pressed = GADSSculpt.tool_active and GADSSculpt.tool_node == node and not GADSVertexPaint.tool_on
		_paint = _button(row, "Paint", "Paint vertex colours in the 3D viewport (left-drag): the layered materials' layer masks (layer 1 red, layer 2 green); each stroke bakes again.", _on_paint)
		_paint.toggle_mode = true
		_paint.button_pressed = PaintInspector.PaintPanel.is_painting(node)
		_sculpt_row = HBoxContainer.new()
		add_child(_sculpt_row)
		var mode := OptionButton.new()
		for m in GADSSculpt.MODE_NAMES:
			mode.add_item(m)
		mode.selected = GADSSculpt.tool_mode
		mode.item_selected.connect(func(i: int) -> void: GADSSculpt.tool_mode = i as GADSSculpt.Mode)
		_sculpt_row.add_child(mode)
		_sculpt_row.add_child(_labeled_spin("Radius (m)", 0.005, 10.0, 0.005, GADSSculpt.tool_radius, func(v: float) -> void: GADSSculpt.tool_radius = v))
		_sculpt_row.add_child(_labeled_spin("Strength (mm)", 0.1, 100.0, 0.1, GADSSculpt.tool_strength * 1000.0,
			func(v: float) -> void: GADSSculpt.tool_strength = v / 1000.0))
		var clear := Button.new()
		clear.text = "Clear Sculpt"
		clear.tooltip_text = "Remove the sculpt map (undoable)."
		clear.pressed.connect(_on_sculpt_clear)
		_sculpt_row.add_child(clear)
		_sculpt_row.visible = _sculpt.button_pressed
		var paint_row := PaintInspector.PaintPanel.new()
		paint_row.node = node
		paint_row.fill = fill
		_paint_row = paint_row
		add_child(_paint_row)
		_paint_row.visible = _paint.button_pressed
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

	func _labeled_spin(text: String, lo: float, hi: float, step: float, value: float, changed: Callable) -> Control:
		var box := HBoxContainer.new()
		var label := Label.new()
		label.text = text
		box.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = lo
		spin.max_value = hi
		spin.step = step
		spin.value = value
		spin.value_changed.connect(changed)
		box.add_child(spin)
		return box

	func _on_paint() -> void:
		PaintInspector.PaintPanel.activate(node, _paint.button_pressed)
		_sculpt.set_pressed_no_signal(false)
		_sculpt_row.visible = false
		_paint_row.visible = _paint.button_pressed

	func _on_sculpt() -> void:
		GADSVertexPaint.tool_on = false
		_paint.set_pressed_no_signal(false)
		_paint_row.visible = false
		GADSSculpt.tool_active = _sculpt.button_pressed
		GADSSculpt.tool_node = node if _sculpt.button_pressed else null
		_sculpt_row.visible = _sculpt.button_pressed

	func _on_sculpt_clear() -> void:
		var before := node.get_sculpt_image().duplicate() if node.sculpt_map != null else null
		undo_redo.create_action("Clear GADS sculpt", UndoRedo.MERGE_DISABLE, node)
		undo_redo.add_do_method(node, "set_sculpt_image", null)
		undo_redo.add_undo_method(node, "set_sculpt_image", before)
		undo_redo.commit_action()

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
		var available := true # without the native library the GDScript tessellator bakes
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

