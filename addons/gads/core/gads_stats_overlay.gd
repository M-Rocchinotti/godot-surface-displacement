@tool
@icon("res://addons/gads/icons/gads_manager.svg")
class_name GADSStatsOverlay
extends CanvasLayer
## A corner panel with what the GADS content of the running scene costs (GADSProfiler): baked and
## generated triangles, parallax surfaces, memory, the preset and the frame's GPU time, and the
## first recommendations. Add it to a scene (or the demo) while tuning; hide it with
## [member toggle_action] or [member shown].

## Refreshes per second.
@export_range(0.5, 10.0, 0.5) var refresh_rate := 2.0
## An input action that shows and hides the panel ("" = none).
@export var toggle_action := &""
@export var shown := true:
	set(value):
		shown = value
		if _panel != null:
			_panel.visible = value
## The scene to profile (empty: the current scene).
@export var target: NodePath

var _panel: PanelContainer
var _label: Label
var _elapsed := 0.0
var _last := {}


func _ready() -> void:
	layer = 100
	_panel = PanelContainer.new()
	_panel.position = Vector2(12, 12)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.visible = shown
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)
	style.set_content_margin_all(8)
	style.set_corner_radius_all(4)
	_panel.add_theme_stylebox_override("panel", style)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 13)
	_panel.add_child(_label)
	add_child(_panel)
	_refresh()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not toggle_action.is_empty() and InputMap.has_action(toggle_action) and Input.is_action_just_pressed(toggle_action):
		shown = not shown
	_elapsed += delta
	if shown and _elapsed >= 1.0 / refresh_rate:
		_elapsed = 0.0
		_refresh()


## The last report (see GADSProfiler.collect).
func get_report() -> Dictionary:
	return _last


func _refresh() -> void:
	var root: Node = get_node_or_null(target) if not target.is_empty() else (get_tree().current_scene if is_inside_tree() else null)
	if root == null or _label == null:
		return
	_last = GADSProfiler.collect(root, get_viewport().get_camera_3d())
	_label.text = describe(_last)


## A few lines of text about a report from GADSProfiler.collect().
static func describe(report: Dictionary) -> String:
	var t: Dictionary = report["totals"]
	var f: Dictionary = report["frame"]
	var lines: Array[String] = []
	lines.append("GADS  %d fps  GPU %s  %s draw calls" % [f["fps"], "%.2f ms" % f["gpu_ms"] if f["gpu_ms"] > 0.0 else "-", f["draw_calls"]])
	if not report["manager"].is_empty():
		lines.append("Preset %s (target %.2f ms)" % [GADSSettings.preset_name(report["manager"]["preset"]), report["manager"]["budget_ms"]])
	lines.append("Baked meshes %d: %s triangles (%s generated from %s), %s" % [t["objects"], GADSProfiler.format_count(t["active_triangles"] - report["surface_triangles"] - report["field_triangles"]),
		GADSProfiler.format_count(t["generated_triangles"]), GADSProfiler.format_count(t["base_triangles"]), GADSProfiler.format_bytes(t["memory_bytes"])])
	lines.append("Parallax surfaces %d (%s triangles), fields %d (%s triangles)" % [report["surfaces"], GADSProfiler.format_count(report["surface_triangles"]),
		report["fields"], GADSProfiler.format_count(report["field_triangles"])])
	lines.append("Frame: %s primitives, %s video memory" % [GADSProfiler.format_count(f["primitives"]), GADSProfiler.format_bytes(f["video_memory_bytes"])])
	var recs: Array = report["recommendations"]
	for i in mini(recs.size(), 3):
		lines.append(("! " if recs[i]["level"] == "warning" else "- ") + String(recs[i]["message"]))
	return "\n".join(lines)
