extends Node
## Surface Displacement demo: four scenes, presets, per-feature switches, a flat / POM /
## POM + geometry comparison, debug views and a frame-time overlay.
## Keys: 1-4 scene, V next camera view, P next preset, B next comparison mode, H hide the panel;
## hold the right mouse button and use WASD/QE to fly (Shift fast, Alt slow).

const Builder := preload("res://demo/scenes/demo_builder.gd")
const FlyCamera := preload("res://demo/fly_camera.gd")
const PRESETS: Array[String] = ["Off", "Low", "Medium", "High", "Epic"]
const COMPARE: Array[String] = ["Flat (normal map)", "POM", "POM + geometry"]
const DEBUG_VIEWS := [["Final", 0], ["Hit offset", 1], ["Cost (steps)", 2], ["Relief height", 3], ["Normals", 4], ["Self-shadow", 5], ["Field levels", 8]]
const PANEL_WIDTH := 300.0

var scene: Node3D
var sd: SurfaceDisplacement
var _scene_index := 0
var _view_index := 0
var _preset := SDSettings.Preset.EPIC
var _panel: PanelContainer
var _scene_option: OptionButton
var _view_option: OptionButton
var _preset_option: OptionButton
var _feature_checks := {}
var _compare_buttons: Array[Button] = []
var _debug_option: OptionButton
var _stats: Label
var _gpu_ms := 0.0
var _frame_ms := 0.0


func _ready() -> void:
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_build_ui()
	load_scene(0)


## Builds scene [param index] (see demo_builder.gd) and keeps the current quality settings.
func load_scene(index: int) -> void:
	_scene_index = index
	var old_sd := sd
	if scene != null:
		scene.queue_free()
		remove_child(scene)
	scene = Builder.build(index)
	add_child(scene)
	sd = scene.get_node("SurfaceDisplacement") as SurfaceDisplacement
	if old_sd != null:
		sd.preset = old_sd.preset
		sd.pom = old_sd.pom
		sd.self_shadow = old_sd.self_shadow
		sd.near_field = old_sd.near_field
		sd.scatter = old_sd.scatter
		sd.depth_write = old_sd.depth_write
		sd.debug_view = old_sd.debug_view
	else:
		sd.preset = _preset
	var cam := scene.get_node("Camera") as Camera3D
	cam.set_script(FlyCamera)
	cam.current = true
	_scene_option.select(index)
	set_view(mini(_view_index, Builder.VIEW_NAMES.size() - 1))
	_sync_ui()


func set_view(index: int) -> void:
	_view_index = index
	var views: Dictionary = scene.get_meta(&"views")
	var cam := scene.get_node("Camera") as Camera3D
	cam.transform = Builder.view_transform(views[Builder.VIEW_NAMES[index]])
	cam.call(&"sync_angles")
	_view_option.select(index)


## Flat: preset Off. POM: Epic parallax without geometry or pebbles. POM + geometry: Epic, all on.
func set_compare(mode: int) -> void:
	sd.preset = SDSettings.Preset.OFF if mode == 0 else SDSettings.Preset.EPIC
	sd.pom = true
	sd.self_shadow = true
	sd.near_field = mode == 2
	sd.scatter = mode == 2
	_sync_ui()


func _compare_mode() -> int:
	if sd.preset == SDSettings.Preset.OFF:
		return 0
	if not sd.is_feature_active(SurfaceDisplacement.Feature.NEAR_FIELD):
		return 1
	return 2


func _sync_ui() -> void:
	_preset_option.select(sd.preset if sd.preset != SDSettings.Preset.CUSTOM else SDSettings.Preset.MEDIUM)
	for feature: int in _feature_checks:
		var check := _feature_checks[feature] as CheckButton
		check.set_pressed_no_signal([sd.pom, sd.self_shadow, sd.near_field, sd.scatter, sd.depth_write][feature])
	var mode := _compare_mode()
	for i in _compare_buttons.size():
		_compare_buttons[i].set_pressed_no_signal(i == mode)
	for i in DEBUG_VIEWS.size():
		if DEBUG_VIEWS[i][1] == int(sd.debug_view):
			_debug_option.select(i)


func _process(delta: float) -> void:
	_frame_ms = lerpf(_frame_ms, delta * 1000.0, 0.1)
	_gpu_ms = lerpf(_gpu_ms, RenderingServer.viewport_get_measured_render_time_gpu(get_viewport().get_viewport_rid()), 0.1)
	if Engine.get_process_frames() % 10 == 0 and sd != null:
		var budget := sd.get_budget_ms()
		_stats.text = "%d fps   frame %.2f ms   GPU %.2f ms\n%s preset, added-cost target %s   (%s)" % [
			Engine.get_frames_per_second(), _frame_ms, _gpu_ms, SDSettings.preset_name(sd.preset),
			"%.1f ms" % budget if budget < INF else "-", RenderingServer.get_video_adapter_name()]


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_1, KEY_2, KEY_3, KEY_4:
			load_scene(key.keycode - KEY_1)
		KEY_V:
			set_view((_view_index + 1) % Builder.VIEW_NAMES.size())
		KEY_P:
			sd.preset = ((int(sd.preset) + 1) % PRESETS.size()) as SDSettings.Preset
			_sync_ui()
		KEY_B:
			set_compare((_compare_mode() + 1) % COMPARE.size())
		KEY_H:
			_panel.visible = not _panel.visible


# --- UI ------------------------------------------------------------------------------------

static func glass_style(radius := 16) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.11, 0.15, 0.62)
	style.border_color = Color(1, 1, 1, 0.16)
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.shadow_color = Color(0, 0, 0, 0.28)
	style.shadow_size = 14
	style.set_content_margin_all(14)
	return style


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	_panel = PanelContainer.new()
	_panel.add_theme_stylebox_override("panel", glass_style())
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.offset_left = -PANEL_WIDTH - 16
	_panel.offset_right = -16
	_panel.offset_top = 16
	layer.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_panel.add_child(box)
	var title := Label.new()
	title.text = "Surface Displacement"
	title.add_theme_font_size_override("font_size", 18)
	box.add_child(title)

	_scene_option = _option(box, "Scene  (1-4)", Builder.SCENE_NAMES, func(i: int) -> void: load_scene(i))
	_view_option = _option(box, "Camera  (V)", Builder.VIEW_NAMES, func(i: int) -> void: set_view(i))
	_section(box, "Quality")
	_preset_option = _option(box, "Preset  (P)", PRESETS, func(i: int) -> void:
		sd.preset = i as SDSettings.Preset
		_sync_ui())
	var names := ["Parallax occlusion (POM)", "Self-shadowing", "Near-camera geometry", "Pebble scatter", "Depth write (opted-in walls)"]
	for feature in names.size():
		var check := CheckButton.new()
		check.text = names[feature]
		check.toggled.connect(func(on: bool) -> void:
			sd.set_feature(feature as SurfaceDisplacement.Feature, on)
			_sync_ui())
		box.add_child(check)
		_feature_checks[feature] = check
	_section(box, "Compare  (B)")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	box.add_child(row)
	var group := ButtonGroup.new()
	for i in COMPARE.size():
		var b := Button.new()
		b.text = ["Flat", "POM", "POM + geo"][i]
		b.tooltip_text = COMPARE[i]
		b.toggle_mode = true
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(func() -> void: set_compare(i))
		row.add_child(b)
		_compare_buttons.append(b)
	_section(box, "Debug")
	_debug_option = _option(box, "View", DEBUG_VIEWS.map(func(v: Array) -> String: return v[0]), func(i: int) -> void:
		sd.debug_view = DEBUG_VIEWS[i][1] as SurfaceDisplacement.DebugView)
	var hint := Label.new()
	hint.text = "Right mouse + WASD/QE: fly   H: hide panel"
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(1, 1, 1, 0.7)
	box.add_child(hint)

	var stats_panel := PanelContainer.new()
	stats_panel.add_theme_stylebox_override("panel", glass_style(12))
	stats_panel.offset_left = 16
	stats_panel.offset_top = 16
	layer.add_child(stats_panel)
	_stats = Label.new()
	_stats.add_theme_font_size_override("font_size", 13)
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["Consolas", "Menlo", "DejaVu Sans Mono", "monospace"])
	_stats.add_theme_font_override("font", mono)
	stats_panel.add_child(_stats)


func _section(parent: Control, text: String) -> void:
	var sep := HSeparator.new()
	sep.modulate = Color(1, 1, 1, 0.35)
	parent.add_child(sep)
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.modulate = Color(1, 1, 1, 0.8)
	parent.add_child(label)


func _option(parent: Control, label_text: String, items: Array, on_select: Callable) -> OptionButton:
	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 12)
	label.modulate = Color(1, 1, 1, 0.75)
	parent.add_child(label)
	var option := OptionButton.new()
	for item: String in items:
		option.add_item(item)
	option.item_selected.connect(on_select)
	parent.add_child(option)
	return option
