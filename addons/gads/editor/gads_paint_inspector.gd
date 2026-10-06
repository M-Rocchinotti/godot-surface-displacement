@tool
extends EditorInspectorPlugin
## The Paint tool at the top of the inspector of a MeshInstance3D drawing a GADS material (a
## GADSMeshInstance3D has it next to Sculpt): with it on, left-drag in the 3D viewport paints a
## vertex colour channel, the layered materials' layer masks. Each stroke is one undoable step; the
## first one gives the node a painted copy of its mesh (see GADSVertexPaint).

## The plugin's fill_paint(node, channel, value): one undoable action.
var fill: Callable


func _can_handle(object: Object) -> bool:
	return can_paint(object)


## Whether [param object] gets this inspector (and the plugin forwards its viewport input): a
## MeshInstance3D, not a GADSMeshInstance3D (its own inspector has Paint), drawing a GADS material.
static func can_paint(object: Object) -> bool:
	if not object is MeshInstance3D or object is GADSMeshInstance3D:
		return false
	for m in GADSMaterials.materials_of(object as MeshInstance3D):
		if GADSMaterials.is_gads_material(m):
			return true
	return false


func _parse_begin(object: Object) -> void:
	var panel := PaintPanel.new()
	panel.node = object as MeshInstance3D
	panel.fill = fill
	var toggle := Button.new()
	toggle.text = "Paint Layers"
	toggle.toggle_mode = true
	toggle.tooltip_text = "Paint vertex colours in the 3D viewport with left-drag: the layered GADS materials' layer masks (layer 1 red, layer 2 green). Each stroke is one undoable step."
	toggle.button_pressed = PaintPanel.is_painting(panel.node)
	toggle.toggled.connect(func(on: bool) -> void:
		PaintPanel.activate(panel.node, on)
		panel.visible = on)
	panel.visible = toggle.button_pressed
	var box := VBoxContainer.new()
	box.add_child(toggle)
	box.add_child(panel)
	add_custom_control(box)


## The Paint tool's settings row: mode, channel, radius, strength, Fill and Clear.
class PaintPanel extends HBoxContainer:
	var node: MeshInstance3D
	var fill: Callable

	## Whether the Paint tool is on for [param target].
	static func is_painting(target: Node3D) -> bool:
		return GADSSculpt.tool_active and GADSSculpt.tool_node == target and GADSVertexPaint.tool_on

	## Switches the viewport tool to painting [param target] (or off).
	static func activate(target: Node3D, on: bool) -> void:
		GADSSculpt.tool_active = on
		GADSSculpt.tool_node = target if on else null
		GADSVertexPaint.tool_on = on

	func _ready() -> void:
		var mode := OptionButton.new()
		for m in GADSVertexPaint.MODE_NAMES:
			mode.add_item(m)
		mode.selected = GADSVertexPaint.tool_mode
		mode.item_selected.connect(func(i: int) -> void: GADSVertexPaint.tool_mode = i as GADSVertexPaint.Mode)
		mode.tooltip_text = "Paint raises the channel towards 1, Erase lowers it towards 0, Smooth evens it out."
		add_child(mode)
		var channel := OptionButton.new()
		for c in GADSVertexPaint.CHANNEL_NAMES:
			channel.add_item(c)
		channel.selected = GADSVertexPaint.tool_channel
		channel.item_selected.connect(func(i: int) -> void: GADSVertexPaint.tool_channel = i)
		channel.tooltip_text = "The vertex colour channel: the layered materials read layer 1 from R and layer 2 from G (their mask_channel)."
		add_child(channel)
		add_child(_spin("Radius (m)", 0.01, 50.0, 0.01, GADSVertexPaint.tool_radius, func(v: float) -> void: GADSVertexPaint.tool_radius = v))
		add_child(_spin("Strength", 0.01, 1.0, 0.01, GADSVertexPaint.tool_strength, func(v: float) -> void: GADSVertexPaint.tool_strength = v))
		for pair in [["Fill Channel", 1.0, "Set the channel to 1 on the whole mesh (undoable)."], ["Clear Channel", 0.0, "Set the channel to 0 on the whole mesh (undoable)."]]:
			var b := Button.new()
			b.text = pair[0]
			b.tooltip_text = pair[2]
			var value: float = pair[1]
			b.pressed.connect(func() -> void:
				if fill.is_valid():
					fill.call(node, GADSVertexPaint.tool_channel, value))
			add_child(b)

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
