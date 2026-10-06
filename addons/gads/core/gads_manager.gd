@tool
@icon("res://addons/gads/icons/gads_manager.svg")
class_name GADSManager
extends Node
## One per scene: applies a quality preset to every GADS material, field and
## pebble scatter, and is the runtime API a game wires to its settings menu.
##
## [codeblock]
## var gads := GADSManager.find_in(get_tree())
## gads.preset = GADSSettings.Preset.HIGH
## gads.set_feature(GADSManager.Feature.SCATTER, false)
## [/codeblock]
##
## What it does: sets the shader globals (steps, fade, self-shadow) and, at runtime, switches each
## GADS material between its flat / POM / POM-with-self-shadow shader variant (materials in scenes
## added later are picked up as they enter the tree), and configures [GADSDisplacementField3D] and
## [GADSPebbleScatter3D] nodes. In the editor it only sets the globals, so saved materials keep the
## variant they were saved with.

signal settings_changed
## The adaptive quality stepped: [param level] steps below the preset (0: the preset itself).
signal quality_adapted(level: int)

enum Feature { POM, SELF_SHADOW, NEAR_FIELD, SCATTER }
enum DebugView { OFF = 0, HIT_OFFSET = 1, COST = 2, RELIEF = 3, NORMALS = 4, SELF_SHADOW = 5, FIELD_LEVELS = 8, TESSELLATION = 9 }

## Off: every GADS material draws as plain normal mapping, no field, no scatter.
@export var enabled := true:
	set(value):
		enabled = value
		_queue_apply()
@export var preset := GADSSettings.Preset.MEDIUM:
	set(value):
		preset = value
		_queue_apply()
## Used when [member preset] is Custom. Changes to its values apply like the node's own.
@export var custom_settings: GADSSettings:
	set(value):
		if custom_settings != null and custom_settings.changed.is_connected(_queue_apply):
			custom_settings.changed.disconnect(_queue_apply)
		custom_settings = value
		if custom_settings != null:
			custom_settings.changed.connect(_queue_apply)
		_queue_apply()
@export_group("Features")
## Feature switches on top of the preset: a feature is on when the preset has it AND its switch
## is on (switches cannot add a feature the preset leaves out).
@export var pom := true:
	set(value):
		pom = value
		_queue_apply()
@export var self_shadow := true:
	set(value):
		self_shadow = value
		_queue_apply()
@export var near_field := true:
	set(value):
		near_field = value
		_queue_apply()
@export var scatter := true:
	set(value):
		scatter = value
		_queue_apply()
@export_group("Platforms")
## The highest preset on a platform or renderer, while the game runs: keys are OS feature tags
## ("mobile", "web", "android", "ios", "macos", "windows", "linuxbsd") or renderers
## ("forward_plus", "mobile_renderer", "gl_compatibility"); values a GADSSettings.Preset. The
## lowest cap that applies wins; Custom is never capped. The defaults keep phones and browsers
## on Low.
@export var platform_caps := {"mobile": GADSSettings.Preset.LOW, "web": GADSSettings.Preset.LOW}:
	set(value):
		platform_caps = value
		_queue_apply()
## Tags to test with instead of the real platform's (e.g. ["mobile"] on a desktop); empty: the
## real ones. See [method get_platform_tags].
@export var simulate_platform := PackedStringArray():
	set(value):
		simulate_platform = value
		_queue_apply()
@export_group("Adaptive quality")
## While the game runs, lower the quality when frames take longer than [member target_frame_ms]
## and bring it back when there is room again, one step at a time: a step down once the target
## has been missed for [member adaptive_down_seconds], a step up after
## [member adaptive_up_seconds] well under it (below 80 %), and a second between steps for the
## measurement to settle. A step lowers the preset by one (down to [member adaptive_min_preset];
## Custom settings keep theirs) and makes runtime tessellation 1.5 times coarser, up to
## [constant ADAPT_MAX_LEVEL] steps. Never above [member preset]. Measured: the main viewport's
## GPU time (or the frame time where the renderer does not measure it); a game that measures its
## own can feed [method adapt_to] instead.
@export var adaptive_quality := false:
	set(value):
		adaptive_quality = value
		if not value:
			_set_adapt_level(0)
		_update_processing()
@export_range(4.0, 100.0, 0.1, "suffix:ms") var target_frame_ms := 16.6
@export var adaptive_min_preset := GADSSettings.Preset.LOW
@export_range(0.1, 10.0, 0.1, "suffix:s") var adaptive_down_seconds := 1.0
@export_range(0.5, 60.0, 0.5, "suffix:s") var adaptive_up_seconds := 4.0
@export_group("Runtime tessellation budget")
## The triangles all view-dependent GADSMeshInstance3D nodes may use together (0: each keeps its
## own [member GADSMeshInstance3D.view_max_triangles]). Shared by how much of the view each covers
## times its [member GADSMeshInstance3D.displacement_priority], never more than a node's own
## maximum (what a capped node leaves goes to the others), at least [constant MIN_SHARE] each.
## Updated four times a second.
@export_range(0, 50000000, 1000, "or_greater") var runtime_triangle_budget := 0:
	set(value):
		runtime_triangle_budget = value
		_update_processing()
@export_group("Weather")
## Surface effects on every GADS material at once (each scaled by its weather_response): rain
## darkens and glosses surfaces, snow covers what faces up, puddles fill low relief on level
## ground. 0..1; applied in the editor too, for a preview.
@export_range(0.0, 1.0, 0.01) var rain_wetness := 0.0:
	set(value):
		rain_wetness = value
		_apply_weather()
@export_range(0.0, 1.0, 0.01) var snow_cover := 0.0:
	set(value):
		snow_cover = value
		_apply_weather()
@export_range(0.0, 1.0, 0.01) var puddle_level := 0.0:
	set(value):
		puddle_level = value
		_apply_weather()
@export_group("Debug")
@export var debug_view := DebugView.OFF:
	set(value):
		debug_view = value
		_queue_apply()

var _materials := {} # instance id -> WeakRef(ShaderMaterial)
var _apply_queued := false
var _adapt_level := 0
var _over_s := 0.0
var _under_s := 0.0
var _settle_s := 0.0
var _smoothed_ms := -1.0
var _measuring := false
var _budget_timer := 0.0
var _limits_pushed := false

## The most steps the adaptive quality takes below the preset.
const ADAPT_MAX_LEVEL := 4
## How much coarser runtime tessellation gets per adaptive step (pixel error factor).
const ADAPT_PIXEL_SCALE := 1.5
## The fewest triangles a view-dependent node gets from a shared budget.
const MIN_SHARE := 1000


## The GADSManager node of [param tree], or null.
static func find_in(tree: SceneTree) -> GADSManager:
	var nodes := tree.get_nodes_in_group(&"gads_manager")
	return nodes[0] as GADSManager if not nodes.is_empty() else null


func _enter_tree() -> void:
	add_to_group(&"gads_manager")
	_update_processing()
	GADSGlobals.ensure_registered()
	if not Engine.is_editor_hint():
		get_tree().node_added.connect(_on_node_added)


func _ready() -> void:
	if not Engine.is_editor_hint():
		register_scene(get_tree().root)
	apply()
	_update_processing()


func _exit_tree() -> void:
	remove_from_group(&"gads_manager")
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


## The settings in effect: the preset (or [member custom_settings]) with the feature switches and
## [member enabled] applied. A new resource; changing it has no effect.
func get_effective_settings() -> GADSSettings:
	var base: GADSSettings
	var effective := get_effective_preset()
	if effective == GADSSettings.Preset.CUSTOM and custom_settings != null:
		base = custom_settings.duplicate()
	else:
		base = GADSSettings.create_preset(effective if effective != GADSSettings.Preset.CUSTOM else GADSSettings.Preset.MEDIUM)
	if not enabled:
		base = GADSSettings.create_preset(GADSSettings.Preset.OFF)
	base.pom_enabled = base.pom_enabled and pom
	if not self_shadow or not base.pom_enabled:
		base.self_shadow = GADSSettings.SelfShadow.OFF
	base.near_field_enabled = base.near_field_enabled and near_field
	base.scatter_enabled = base.scatter_enabled and scatter and base.near_field_enabled
	return base


func set_feature(feature: Feature, on: bool) -> void:
	match feature:
		Feature.POM:
			pom = on
		Feature.SELF_SHADOW:
			self_shadow = on
		Feature.NEAR_FIELD:
			near_field = on
		Feature.SCATTER:
			scatter = on


## Whether [param feature] is on in the effective settings (preset and switch).
func is_feature_active(feature: Feature) -> bool:
	var s := get_effective_settings()
	match feature:
		Feature.POM:
			return s.pom_enabled
		Feature.SELF_SHADOW:
			return s.self_shadow != GADSSettings.SelfShadow.OFF
		Feature.NEAR_FIELD:
			return s.near_field_enabled
		_:
			return s.scatter_enabled


## The preset in effect: [member preset], capped for the platform ([member platform_caps],
## while the game runs) and lowered by the adaptive quality's steps (not below
## [member adaptive_min_preset]); Off and Custom are never capped or stepped.
func get_effective_preset() -> GADSSettings.Preset:
	if preset == GADSSettings.Preset.OFF or preset == GADSSettings.Preset.CUSTOM:
		return preset
	var base := preset
	if not Engine.is_editor_hint():
		base = mini(base, platform_cap(platform_caps, get_platform_tags())) as GADSSettings.Preset
	if _adapt_level == 0:
		return base
	var floor_preset := clampi(adaptive_min_preset, GADSSettings.Preset.LOW, base)
	return maxi(base - _adapt_level, floor_preset) as GADSSettings.Preset


## The highest preset [param caps] allow for a platform with [param tags] (the lowest matching
## cap; Ultra when none matches).
static func platform_cap(caps: Dictionary, tags: PackedStringArray) -> int:
	var cap := GADSSettings.Preset.ULTRA as int
	for tag: String in tags:
		if caps.has(tag):
			cap = mini(cap, int(caps[tag]))
	return cap


## The tags [member platform_caps] match against: [member simulate_platform] when set, otherwise
## the OS feature tags of this platform and the renderer ("forward_plus", "mobile_renderer" or
## "gl_compatibility").
func get_platform_tags() -> PackedStringArray:
	if not simulate_platform.is_empty():
		return simulate_platform
	var tags := PackedStringArray()
	for tag in ["mobile", "web", "android", "ios", "macos", "windows", "linuxbsd", "pc"]:
		if OS.has_feature(tag):
			tags.append(tag)
	tags.append(renderer_tag())
	return tags


## The current renderer as a platform tag: "forward_plus", "mobile_renderer" or "gl_compatibility".
static func renderer_tag() -> String:
	var method := RenderingServer.get_current_rendering_method()
	return "mobile_renderer" if method == "mobile" else method


## What this machine supports of GADS: {"renderer" (tag), "native_library" (bakes, runtime
## tessellation, procedural maps), "rendering_device" (the runtime ground capture of fields),
## "tags", "cap" (the preset cap that applies)}. Unsupported parts fall back on their own: a
## mesh that cannot bake draws its source with parallax, a field without ground data stays off,
## and every material keeps at least normal mapping.
func get_capabilities() -> Dictionary:
	var tags := get_platform_tags()
	return {
		"renderer": renderer_tag(),
		"native_library": GADSMeshBaker.is_available(),
		"rendering_device": RenderingServer.get_rendering_device() != null,
		"tags": tags,
		"cap": platform_cap(platform_caps, tags),
	}


## How many steps the adaptive quality is below the preset (0: none).
func get_adapt_level() -> int:
	return _adapt_level


## How much coarser than their pixel_error view-dependent meshes tessellate because of the
## adaptive quality (1: not at all).
func get_runtime_detail_scale() -> float:
	return pow(ADAPT_PIXEL_SCALE, _adapt_level)


## The frame time the adaptive quality reacts to, smoothed (ms; -1 before the first frame).
func get_measured_frame_ms() -> float:
	return _smoothed_ms


## Feeds one frame of [param frame_ms] (taking [param delta] seconds) to the adaptive quality.
## Called every frame while [member adaptive_quality] is on, with the measured time.
func adapt_to(frame_ms: float, delta: float) -> void:
	_smoothed_ms = frame_ms if _smoothed_ms < 0.0 else lerpf(_smoothed_ms, frame_ms, clampf(delta * 4.0, 0.0, 1.0))
	if _settle_s > 0.0:
		_settle_s -= delta
		_over_s = 0.0
		_under_s = 0.0
		return
	if _smoothed_ms > target_frame_ms * 1.05:
		_over_s += delta
		_under_s = 0.0
	elif _smoothed_ms < target_frame_ms * 0.8:
		_under_s += delta
		_over_s = 0.0
	else:
		_over_s = 0.0
		_under_s = 0.0
	if _over_s >= adaptive_down_seconds and _adapt_level < ADAPT_MAX_LEVEL:
		_set_adapt_level(_adapt_level + 1)
	elif _under_s >= adaptive_up_seconds and _adapt_level > 0:
		_set_adapt_level(_adapt_level - 1)


func _set_adapt_level(level: int) -> void:
	if level == _adapt_level:
		return
	_adapt_level = level
	_over_s = 0.0
	_under_s = 0.0
	_settle_s = 1.0
	_queue_apply()
	_budget_timer = 0.0
	quality_adapted.emit(level)


## Splits [param budget] triangles among [param entries] ({"priority" (0-100), "radius" and
## "distance" (m), "max" (triangles)}): by priority times the share of the view each covers
## ((radius / distance)^2, the distance at least the radius), each at most its "max"; what a
## capped entry leaves goes to the others. Every entry gets at least [constant MIN_SHARE].
static func share_budget(budget: int, entries: Array) -> PackedInt32Array:
	var n := entries.size()
	var out := PackedInt32Array()
	out.resize(n)
	var weights := PackedFloat64Array()
	weights.resize(n)
	var caps := PackedInt32Array()
	caps.resize(n)
	var open: Array[int] = []
	var left := float(budget)
	for i in n:
		var e: Dictionary = entries[i]
		var r := maxf(float(e.get("radius", 1.0)), 1e-3)
		var cover := r / maxf(float(e.get("distance", r)), r)
		weights[i] = clampf(float(e.get("priority", 50)), 0.0, 100.0) / 100.0 * cover * cover
		caps[i] = int(e.get("max", 1 << 30))
		if weights[i] > 0.0:
			open.append(i)
		else:
			out[i] = mini(MIN_SHARE, caps[i])
			left -= out[i]
	# Water-filling: entries whose share would pass their maximum get the maximum (which frees
	# budget for the others), then entries whose share would fall under the minimum get the
	# minimum; each time the rest is shared again among the others.
	while not open.is_empty():
		var total := 0.0
		for i in open:
			total += weights[i]
		var capped: Array[int] = []
		var floored: Array[int] = []
		for i in open:
			var share := maxf(left, 0.0) * weights[i] / total
			if share >= caps[i]:
				capped.append(i)
			elif share < MIN_SHARE:
				floored.append(i)
		var fix := capped if not capped.is_empty() else floored
		if fix.is_empty():
			for i in open:
				out[i] = int(left * weights[i] / total)
			break
		for i in fix:
			out[i] = caps[i] if fix == capped else mini(MIN_SHARE, caps[i])
			left -= out[i]
			open.erase(i)
	return out


## Shares [member runtime_triangle_budget] among the view-dependent GADSMeshInstance3D nodes and
## hands them the adaptive quality's detail scale (four times a second while either is on; call it
## to apply a change at once).
func distribute_runtime_budget() -> void:
	if not is_inside_tree():
		return
	var nodes := get_tree().get_nodes_in_group(&"gads_view_dependent")
	var scale := get_runtime_detail_scale()
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	if runtime_triangle_budget <= 0 or cam == null:
		for node in nodes:
			(node as GADSMeshInstance3D).set_runtime_limits(-1, scale)
		_limits_pushed = scale != 1.0
		return
	var entries := []
	for node in nodes:
		var mi := node as GADSMeshInstance3D
		var aabb := mi.global_transform * mi.source_mesh.get_aabb() if mi.source_mesh != null else AABB()
		entries.append({"priority": mi.displacement_priority, "radius": aabb.size.length() * 0.5,
			"distance": cam.global_position.distance_to(aabb.get_center()), "max": mi.view_max_triangles})
	var shares := share_budget(runtime_triangle_budget, entries)
	for i in nodes.size():
		(nodes[i] as GADSMeshInstance3D).set_runtime_limits(shares[i], scale)
	_limits_pushed = true


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if adaptive_quality:
		adapt_to(_measure_frame_ms(delta), delta)
	if runtime_triangle_budget > 0 or _adapt_level > 0 or _limits_pushed:
		_budget_timer -= delta
		if _budget_timer <= 0.0:
			_budget_timer = 0.25
			distribute_runtime_budget()


func _measure_frame_ms(delta: float) -> float:
	var vp := get_viewport().get_viewport_rid()
	if not _measuring:
		RenderingServer.viewport_set_measure_render_time(vp, true)
		_measuring = true
	var gpu := RenderingServer.viewport_get_measured_render_time_gpu(vp)
	if gpu > 0.0:
		return maxf(gpu, RenderingServer.viewport_get_measured_render_time_cpu(vp))
	return delta * 1000.0


func _update_processing() -> void:
	set_process(not Engine.is_editor_hint() and (adaptive_quality or runtime_triangle_budget > 0 or _adapt_level > 0 or _limits_pushed))


## Sets the weather: [member rain_wetness], [member snow_cover] and [member puddle_level] (0..1).
func set_weather(rain: float, snow: float, puddles: float) -> void:
	rain_wetness = rain
	snow_cover = snow
	puddle_level = puddles


func _apply_weather() -> void:
	if is_inside_tree():
		GADSGlobals.set_value(GADSGlobals.WEATHER, Vector4(rain_wetness, snow_cover, puddle_level, 0.0))


## The target added GPU time of the preset in effect (ms), see [method GADSSettings.get_budget_ms].
func get_budget_ms() -> float:
	return GADSSettings.get_budget_ms(get_effective_preset() if enabled else GADSSettings.Preset.OFF)


## Adds [param material] to the materials this node switches (automatic for materials on
## geometry in the scene tree; use it for materials applied later by code).
func register_material(material: Material) -> void:
	_register_materials([material])


## Registers the GADS materials of every node under [param root] that draws geometry (see
## [method GADSMaterials.materials_of]: meshes, multimeshes, particles, CSG shapes, GridMaps).
func register_scene(root: Node) -> void:
	_register_node(root)
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		_register_node(node)
	for node in root.find_children("*", "GridMap", true, false):
		_register_node(node)


## Registered materials that still exist.
func get_registered_materials() -> Array[ShaderMaterial]:
	var out: Array[ShaderMaterial] = []
	for id: int in _materials.keys():
		var m: ShaderMaterial = (_materials[id] as WeakRef).get_ref()
		if m == null:
			_materials.erase(id)
		else:
			out.append(m)
	return out


## Applies the current settings now (property changes apply at the end of the frame).
func apply() -> void:
	_apply_queued = false
	if not is_inside_tree():
		return
	var s := get_effective_settings()
	s.apply_globals()
	_apply_weather()
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(debug_view, 0.1, 0.0, 0.0))
	# In the editor only the globals change: materials keep the variant they are saved with, and
	# fields and scatters keep their saved properties (they are scene data).
	if not Engine.is_editor_hint():
		var quality := s.get_quality()
		for m in get_registered_materials():
			GADSMaterials.set_quality(m, quality)
		for node in get_tree().get_nodes_in_group(&"gads_field"):
			var field := node as GADSDisplacementField3D
			field.visible = s.near_field_enabled
			field.set_quality(quality)
			if s.near_field_enabled:
				field.levels = s.near_field_levels
				field.resolution = s.near_field_resolution
				field.base_spacing = s.near_field_spacing
		for node in get_tree().get_nodes_in_group(&"gads_scatter"):
			var scatter_node := node as GADSPebbleScatter3D
			scatter_node.visible = s.scatter_enabled
			scatter_node.density = s.scatter_density
			scatter_node.radius = s.scatter_radius
	settings_changed.emit()


func _queue_apply() -> void:
	if _apply_queued or not is_inside_tree():
		return
	_apply_queued = true
	apply.call_deferred()


func _on_node_added(node: Node) -> void:
	if node is GeometryInstance3D or node.is_class("GridMap"):
		_register_node(node)
	elif node is GADSDisplacementField3D or node is GADSPebbleScatter3D:
		_queue_apply()


func _register_node(node: Node) -> void:
	if node is GeometryInstance3D or node.is_class("GridMap"):
		_register_materials(GADSMaterials.materials_of(node))


func _register_materials(materials: Array) -> void:
	var switch := not Engine.is_editor_hint() and is_inside_tree()
	var quality := GADSMaterials.Quality.FLAT
	var quality_known := false
	for material: Material in materials:
		if not GADSMaterials.is_gads_material(material):
			continue
		_materials[material.get_instance_id()] = weakref(material)
		if switch:
			if not quality_known:
				quality = get_effective_settings().get_quality()
				quality_known = true
			GADSMaterials.set_quality(material, quality)
