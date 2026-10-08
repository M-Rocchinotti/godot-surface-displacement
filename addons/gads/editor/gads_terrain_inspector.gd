@tool
extends EditorInspectorPlugin
## The terrain's Sculpt / Paint tool at the top of a GADSTerrain3D's inspector: with it on,
## left-drag in the 3D viewport raises, lowers, smooths or flattens the heights, paints a layer or
## cuts and fills holes.
## Each stroke is one undoable step; the edited maps are saved into the terrain's data directory.

const MODES := ["Raise", "Lower", "Smooth", "Flatten", "Paint layer 2", "Paint layer 3", "Erase layers", "Cut holes", "Fill holes"]
## GADSSculpt.tool_paint values of the hole brushes (the layer brushes use 0-2).
const CUT_HOLES := 10
const FILL_HOLES := 11
const KINDS := ["ridged", "noise", "billow", "craters"]

## The plugin's edit_terrain_heights(terrain, action name, callable): one undoable action.
var edit_heights: Callable


func _can_handle(object: Object) -> bool:
	return object is GADSTerrain3D


func _parse_begin(object: Object) -> void:
	var panel := ToolPanel.new()
	panel.terrain = object as GADSTerrain3D
	panel.edit_heights = edit_heights
	add_custom_control(panel)


class ToolPanel extends VBoxContainer:
	var terrain: GADSTerrain3D
	var edit_heights: Callable
	var _toggle: Button
	var _row: HBoxContainer
	var _kind: OptionButton
	var _seed: SpinBox
	var _features: SpinBox

	func _ready() -> void:
		_toggle = Button.new()
		_toggle.text = "Sculpt / Paint"
		_toggle.toggle_mode = true
		_toggle.tooltip_text = "Edit the terrain in the 3D viewport with left-drag: raise, lower, smooth or flatten the heights, or paint a layer. Each stroke is one undoable step."
		_toggle.button_pressed = GADSSculpt.tool_active and GADSSculpt.tool_node == terrain
		_toggle.toggled.connect(_on_toggled)
		add_child(_toggle)
		_row = HBoxContainer.new()
		add_child(_row)
		var mode := OptionButton.new()
		for m in MODES:
			mode.add_item(m)
		mode.selected = mode_index()
		mode.item_selected.connect(set_mode)
		_row.add_child(mode)
		_row.add_child(_spin("Radius (m)", 0.25, 500.0, 0.25, GADSSculpt.terrain_radius, func(v: float) -> void: GADSSculpt.terrain_radius = v))
		_row.add_child(_spin("Strength (cm)", 0.5, 1000.0, 0.5, GADSSculpt.terrain_strength * 100.0,
			func(v: float) -> void: GADSSculpt.terrain_strength = v / 100.0))
		_row.visible = _toggle.button_pressed
		if GADSProcedural.is_available():
			var gen := HBoxContainer.new()
			add_child(gen)
			_kind = OptionButton.new()
			for k in KINDS:
				_kind.add_item(k.capitalize())
			gen.add_child(_kind)
			var seed_box := _spin("Seed", 0, 99999, 1, 1, func(_v: float) -> void: pass)
			_seed = seed_box.get_child(1) as SpinBox
			gen.add_child(seed_box)
			var features_box := _spin("Features", 1, 64, 1, 4, func(_v: float) -> void: pass)
			_features = features_box.get_child(1) as SpinBox
			gen.add_child(features_box)
			var generate := Button.new()
			generate.text = "Generate"
			generate.tooltip_text = "Replace the heights by a generated landscape (undoable)."
			generate.pressed.connect(_on_generate)
			gen.add_child(generate)
			var erode := Button.new()
			erode.text = "Erode"
			erode.tooltip_text = "Erode the heights: water carves gullies and fills valleys, steep slopes slide into scree (undoable)."
			erode.pressed.connect(_on_erode)
			gen.add_child(erode)
		var export_button := Button.new()
		export_button.text = "Export Heightmap"
		export_button.tooltip_text = "Write the heights (one texel per vertex, 0..1 over the height scale) to a float EXR for other tools."
		export_button.pressed.connect(_on_export)
		add_child(export_button)

	func _spin(text: String, lo: float, hi: float, step: float, value: float, changed: Callable) -> Control:
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

	static func mode_index() -> int:
		match GADSSculpt.tool_paint:
			1:
				return 4
			2:
				return 5
			0:
				return 6
			CUT_HOLES:
				return 7
			FILL_HOLES:
				return 8
		return GADSSculpt.tool_mode

	static func set_mode(index: int) -> void:
		if index < 4:
			GADSSculpt.tool_mode = index as GADSSculpt.Mode
			GADSSculpt.tool_paint = -1
		else:
			GADSSculpt.tool_paint = [1, 2, 0, CUT_HOLES, FILL_HOLES][index - 4]

	func _on_generate() -> void:
		var kind: String = KINDS[_kind.selected]
		var params := {"seed": int(_seed.value), "scale": _features.value}
		_edit("Generate GADS Terrain", func() -> void: terrain.generate_heights(kind, params))

	func _on_erode() -> void:
		_edit("Erode GADS Terrain", func() -> void: terrain.erode({"seed": int(_seed.value)}))

	func _on_export() -> void:
		var dialog := EditorFileDialog.new()
		dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		dialog.title = "Export Terrain Heightmap"
		dialog.filters = PackedStringArray(["*.exr ; OpenEXR"])
		dialog.current_file = String(terrain.name).to_snake_case() + "_height.exr"
		dialog.file_selected.connect(func(path: String) -> void:
			var err := terrain.export_heightmap(path)
			if err != OK:
				push_warning("GADS: cannot export the heightmap to %s (%s)." % [path, error_string(err)])
			dialog.queue_free())
		dialog.canceled.connect(dialog.queue_free)
		EditorInterface.get_base_control().add_child(dialog)
		dialog.popup_file_dialog()

	func _edit(action: String, edit: Callable) -> void:
		if edit_heights.is_valid():
			edit_heights.call(terrain, action, edit)
		else:
			edit.call()

	func _on_toggled(on: bool) -> void:
		GADSSculpt.tool_active = on
		GADSSculpt.tool_node = terrain if on else null
		_row.visible = on
