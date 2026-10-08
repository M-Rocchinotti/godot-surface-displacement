@tool
extends EditorInspectorPlugin
## A row at the top of a GADS material's inspector: its mapping, and switches for the quality
## (flat, parallax, parallax with self-shadowing), the depth write and silhouette parallax. Each is
## one undoable change of the variant (the shader) the material uses; its parameters stay.

const QUALITY_LABELS := ["Flat (normal map)", "Parallax", "Parallax + self-shadow"]
const MAPPING_LABELS := ["UV", "World", "Triplanar"]

var undo_redo: EditorUndoRedoManager


func _can_handle(object: Object) -> bool:
	return object is ShaderMaterial and GADSMaterials.is_gads_material(object as ShaderMaterial)


func _parse_begin(object: Object) -> void:
	var panel := VariantPanel.new()
	panel.target = object as ShaderMaterial
	panel.undo_redo = undo_redo
	add_custom_control(panel)


class VariantPanel extends VBoxContainer:
	var target: ShaderMaterial
	var undo_redo: EditorUndoRedoManager
	var _quality: OptionButton
	var _depth: CheckBox
	var _silhouette: CheckBox

	func _ready() -> void:
		var info := GADSMaterials.parse(target.shader)
		var title := Label.new()
		title.text = "GADS target: %s mapping%s" % [MAPPING_LABELS[info["mapping"]], ", layered" if info["layered"] else ""]
		add_child(title)
		var row := HBoxContainer.new()
		add_child(row)
		_quality = OptionButton.new()
		for q in QUALITY_LABELS:
			_quality.add_item(q)
		_quality.tooltip_text = "The variant's quality (a GADSManager switches it at runtime by its preset)."
		_quality.item_selected.connect(func(i: int) -> void: set_quality(i as GADSMaterials.Quality))
		row.add_child(_quality)
		_depth = CheckBox.new()
		_depth.text = "Depth write"
		_depth.tooltip_text = "Write the relief's depth, so props are cut where the relief is (costs early depth testing)."
		_depth.toggled.connect(set_depth_write)
		row.add_child(_depth)
		_silhouette = CheckBox.new()
		_silhouette.text = "Silhouette"
		_silhouette.tooltip_text = "Silhouette parallax for curved props: the relief shows in the outline (UV mapping)."
		_silhouette.toggled.connect(set_silhouette)
		_silhouette.visible = info["mapping"] == GADSMaterials.Mapping.UV and not info["layered"]
		row.add_child(_silhouette)
		_refresh()

	func _refresh() -> void:
		var info := GADSMaterials.parse(target.shader)
		if info.is_empty():
			return
		_quality.select(info["quality"])
		_depth.set_pressed_no_signal(info["depth_write"] or bool(target.get_meta(&"gads_depth_write", false)))
		_silhouette.set_pressed_no_signal(info["silhouette"] or bool(target.get_meta(&"gads_silhouette", false)))

	## Switches the target to [param quality] (undoable).
	func set_quality(quality: GADSMaterials.Quality) -> void:
		_change("Set GADS Material Quality", func() -> void: GADSMaterials.set_quality(target, quality))

	## Turns the depth write on or off (undoable).
	func set_depth_write(on: bool) -> void:
		_change("Set GADS Depth Write", func() -> void: GADSMaterials.set_depth_write(target, on))

	## Turns silhouette parallax on or off (undoable).
	func set_silhouette(on: bool) -> void:
		_change("Set GADS Silhouette", func() -> void: GADSMaterials.set_silhouette(target, on))

	func _change(action: String, edit: Callable) -> void:
		var before := _state()
		edit.call()
		var after := _state()
		if undo_redo != null and before != after:
			undo_redo.create_action(action, UndoRedo.MERGE_DISABLE, target)
			undo_redo.add_do_property(target, "shader", after[0])
			undo_redo.add_do_method(target, "set_meta", &"gads_depth_write", after[1])
			undo_redo.add_do_method(target, "set_meta", &"gads_silhouette", after[2])
			undo_redo.add_undo_property(target, "shader", before[0])
			undo_redo.add_undo_method(target, "set_meta", &"gads_depth_write", before[1])
			undo_redo.add_undo_method(target, "set_meta", &"gads_silhouette", before[2])
			undo_redo.commit_action(false)
		_refresh()

	## The shader and the switches it remembers for the way back from a flat variant.
	func _state() -> Array:
		return [target.shader, bool(target.get_meta(&"gads_depth_write", false)), bool(target.get_meta(&"gads_silhouette", false))]
