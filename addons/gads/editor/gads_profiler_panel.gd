@tool
extends VBoxContainer
## The GADS bottom panel: what the edited scene's GADS content costs (GADSProfiler), object by
## object, the recommendations with a Fix button each, and Optimize for a hardware target. Every
## change is undoable.

## The Target list's item for a custom GPU budget (after the hardware targets).
const CUSTOM_BUDGET := 100

var undo_redo: EditorUndoRedoManager

var _summary: Label
var _tree: Tree
var _recs: VBoxContainer
var _target: OptionButton
var _budget: SpinBox
var _report := {}


func _ready() -> void:
	name = "GADS"
	custom_minimum_size = Vector2(0, 220)
	var bar := HBoxContainer.new()
	add_child(bar)
	var refresh := Button.new()
	refresh.text = "Refresh"
	refresh.tooltip_text = "Measure the edited scene again."
	refresh.pressed.connect(refresh_report)
	bar.add_child(refresh)
	bar.add_child(VSeparator.new())
	var target_label := Label.new()
	target_label.text = "Target:"
	bar.add_child(target_label)
	_target = OptionButton.new()
	for t in GADSProfiler.TARGETS:
		_target.add_item(GADSProfiler.TARGETS[t]["name"], t)
	_target.add_item("Custom GPU budget", CUSTOM_BUDGET)
	_target.select(GADSProfiler.Target.MAINSTREAM)
	bar.add_child(_target)
	_budget = SpinBox.new()
	_budget.min_value = 0.0
	_budget.max_value = 20.0
	_budget.step = 0.1
	_budget.value = 1.5
	_budget.suffix = "ms"
	_budget.tooltip_text = "The GPU time per frame GADS may add: the highest preset whose measured cost fits."
	_budget.visible = false
	_target.item_selected.connect(func(i: int) -> void: _budget.visible = _target.get_item_id(i) == CUSTOM_BUDGET)
	bar.add_child(_budget)
	var optimize := Button.new()
	optimize.text = "Optimize for Target"
	optimize.tooltip_text = "Set the GADSManager preset and each baked mesh's geometry_range for the target (settings only; undoable)."
	optimize.pressed.connect(_on_optimize)
	bar.add_child(optimize)
	_summary = Label.new()
	_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	bar.add_child(_summary)
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(split)
	_tree = Tree.new()
	_tree.columns = 6
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for c in 6:
		_tree.set_column_title(c, ["Baked mesh", "Triangles", "Source", "Screen", "Memory", "State"][c])
		_tree.set_column_expand(c, c == 0)
	_tree.item_activated.connect(_on_item_activated)
	split.add_child(_tree)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(scroll)
	_recs = VBoxContainer.new()
	_recs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_recs)
	refresh_report()


## The last report (see GADSProfiler.collect()).
func get_report() -> Dictionary:
	return _report


func refresh_report() -> void:
	var root := EditorInterface.get_edited_scene_root()
	_tree.clear()
	for child in _recs.get_children():
		child.queue_free()
	if root == null:
		_summary.text = "Open a scene."
		_report = {}
		return
	var camera: Camera3D = null
	var vp := EditorInterface.get_editor_viewport_3d(0)
	if vp != null:
		camera = vp.get_camera_3d()
	_report = GADSProfiler.collect(root, camera)
	var t: Dictionary = _report["totals"]
	_summary.text = "  %d baked: %s triangles from %s, %s, cache %s | %d parallax surfaces | %d fields | %s" % [
		t["objects"], GADSProfiler.format_count(t["active_triangles"] - _report["surface_triangles"] - _report["field_triangles"]),
		GADSProfiler.format_count(t["base_triangles"]), GADSProfiler.format_bytes(t["memory_bytes"]), GADSProfiler.format_bytes(t["cache_bytes"]),
		_report["surfaces"], _report["fields"],
		"preset %s" % GADSSettings.preset_name(_report["manager"]["preset"]) if not _report["manager"].is_empty() else "no GADSManager"]
	var tree_root := _tree.create_item()
	for o: Dictionary in _report["objects"]:
		var item := _tree.create_item(tree_root)
		item.set_text(0, o["name"])
		item.set_metadata(0, o["node"])
		item.set_text(1, GADSProfiler.format_count(o["triangles"]))
		item.set_text(2, GADSProfiler.format_count(o["base_triangles"]))
		item.set_text(3, "%.1f %%" % (o["coverage"] * 100.0) if o["coverage"] >= 0.0 else "-")
		item.set_text(4, GADSProfiler.format_bytes(o["memory_bytes"]))
		item.set_text(5, "not baked" if not o["baked"] else ("stale" if o["stale"] else ("budget reached" if o["budget_reached"] else "ok")))
	for r: Dictionary in _report["recommendations"]:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = ("Warning: " if r["level"] == "warning" else "") + String(r["message"])
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		if not (r["fix"] as Dictionary).is_empty():
			var fix := Button.new()
			fix.text = "Fix"
			fix.pressed.connect(apply_fixes.bind([r["fix"]], "GADS: apply recommendation"))
			row.add_child(fix)
		_recs.add_child(row)
	if (_report["recommendations"] as Array).is_empty():
		var ok := Label.new()
		ok.text = "No recommendations."
		_recs.add_child(ok)


## Applies fixes (see GADSProfiler) as one undoable action, then measures again.
func apply_fixes(fixes: Array, action := "GADS: optimize") -> void:
	if fixes.is_empty():
		return
	undo_redo.create_action(action)
	for fix: Dictionary in fixes:
		var object: Object = fix["object"]
		if fix.has("property"):
			undo_redo.add_do_property(object, fix["property"], fix["value"])
			undo_redo.add_undo_property(object, fix["property"], object.get(fix["property"]))
		elif fix.has("method") and object is GADSMeshInstance3D and fix["method"] == "bake":
			var node := object as GADSMeshInstance3D
			var before := node.get_bake_state()
			node.bake()
			undo_redo.add_do_method(node, "set_bake_state", node.get_bake_state())
			undo_redo.add_undo_method(node, "set_bake_state", before)
	undo_redo.commit_action()
	refresh_report.call_deferred()


func _on_optimize() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var id := _target.get_selected_id()
	var target: GADSProfiler.Target = GADSProfiler.target_for_budget(_budget.value) if id == CUSTOM_BUDGET else id as GADSProfiler.Target
	apply_fixes(GADSProfiler.optimize_for(target, root), "GADS: optimize for %s" % GADSProfiler.TARGETS[target]["name"])


func _on_item_activated() -> void:
	var item := _tree.get_selected()
	if item != null and is_instance_valid(item.get_metadata(0)):
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(item.get_metadata(0))
