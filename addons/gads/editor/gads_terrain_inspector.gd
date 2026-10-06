@tool
extends EditorInspectorPlugin
## The terrain's Sculpt / Paint tool at the top of a GADSTerrain3D's inspector: with it on,
## left-drag in the 3D viewport raises, lowers, smooths or flattens the heights or paints a layer.
## Each stroke is one undoable step; the edited maps are saved into the terrain's data directory.

const MODES := ["Raise", "Lower", "Smooth", "Flatten", "Paint layer 2", "Paint layer 3", "Erase layers"]


func _can_handle(object: Object) -> bool:
	return object is GADSTerrain3D


func _parse_begin(object: Object) -> void:
	var panel := ToolPanel.new()
	panel.terrain = object as GADSTerrain3D
	add_custom_control(panel)


class ToolPanel extends VBoxContainer:
	var terrain: GADSTerrain3D
	var _toggle: Button
	var _row: HBoxContainer

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
		return GADSSculpt.tool_mode

	static func set_mode(index: int) -> void:
		if index < 4:
			GADSSculpt.tool_mode = index as GADSSculpt.Mode
			GADSSculpt.tool_paint = -1
		else:
			GADSSculpt.tool_paint = [1, 2, 0][index - 4]

	func _on_toggled(on: bool) -> void:
		GADSSculpt.tool_active = on
		GADSSculpt.tool_node = terrain if on else null
		_row.visible = on
