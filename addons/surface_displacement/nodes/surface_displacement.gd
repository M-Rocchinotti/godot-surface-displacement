@tool
@icon("res://addons/surface_displacement/icons/surface_displacement.svg")
class_name SurfaceDisplacement
extends Node
## One per scene: applies a quality preset to every Surface Displacement material, field and
## pebble scatter, and is the runtime API a game wires to its settings menu.
##
## [codeblock]
## var sd := SurfaceDisplacement.find_in(get_tree())
## sd.preset = SDSettings.Preset.HIGH
## sd.set_feature(SurfaceDisplacement.Feature.SCATTER, false)
## [/codeblock]
##
## What it does: sets the shader globals (steps, fade, self-shadow) and, at runtime, switches each
## SD material between its flat / POM / POM-with-self-shadow shader variant (materials in scenes
## added later are picked up as they enter the tree), and configures [DisplacementField3D] and
## [PebbleScatter3D] nodes. In the editor it only sets the globals, so saved materials keep the
## variant they were saved with.

signal settings_changed

enum Feature { POM, SELF_SHADOW, NEAR_FIELD, SCATTER, DEPTH_WRITE }
enum DebugView { OFF = 0, HIT_OFFSET = 1, COST = 2, RELIEF = 3, NORMALS = 4, SELF_SHADOW = 5, FIELD_LEVELS = 8 }

## Off: every SD material draws as plain normal mapping, no field, no scatter.
@export var enabled := true:
	set(value):
		enabled = value
		_queue_apply()
@export var preset := SDSettings.Preset.MEDIUM:
	set(value):
		preset = value
		_queue_apply()
## Used when [member preset] is Custom.
@export var custom_settings: SDSettings:
	set(value):
		custom_settings = value
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
## The depth write of the materials that opted into it ([method SDMaterials.set_depth_write]).
@export var depth_write := true:
	set(value):
		depth_write = value
		_queue_apply()
@export_group("Debug")
@export var debug_view := DebugView.OFF:
	set(value):
		debug_view = value
		_queue_apply()

var _materials := {} # instance id -> WeakRef(ShaderMaterial)
var _apply_queued := false


## The SurfaceDisplacement node of [param tree], or null.
static func find_in(tree: SceneTree) -> SurfaceDisplacement:
	var nodes := tree.get_nodes_in_group(&"surface_displacement_manager")
	return nodes[0] as SurfaceDisplacement if not nodes.is_empty() else null


func _enter_tree() -> void:
	add_to_group(&"surface_displacement_manager")
	SDGlobals.ensure_registered()
	if not Engine.is_editor_hint():
		get_tree().node_added.connect(_on_node_added)


func _ready() -> void:
	if not Engine.is_editor_hint():
		register_scene(get_tree().root)
	apply()


func _exit_tree() -> void:
	remove_from_group(&"surface_displacement_manager")
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


## The settings in effect: the preset (or [member custom_settings]) with the feature switches and
## [member enabled] applied. A new resource; changing it has no effect.
func get_effective_settings() -> SDSettings:
	var base: SDSettings
	if preset == SDSettings.Preset.CUSTOM and custom_settings != null:
		base = custom_settings.duplicate()
	else:
		base = SDSettings.create_preset(preset if preset != SDSettings.Preset.CUSTOM else SDSettings.Preset.MEDIUM)
	if not enabled:
		base = SDSettings.create_preset(SDSettings.Preset.OFF)
	base.pom_enabled = base.pom_enabled and pom
	if not self_shadow or not base.pom_enabled:
		base.self_shadow = SDSettings.SelfShadow.OFF
	base.near_field_enabled = base.near_field_enabled and near_field
	base.scatter_enabled = base.scatter_enabled and scatter and base.near_field_enabled
	base.depth_write_enabled = base.depth_write_enabled and depth_write and base.pom_enabled
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
		Feature.DEPTH_WRITE:
			depth_write = on


## Whether [param feature] is on in the effective settings (preset and switch).
func is_feature_active(feature: Feature) -> bool:
	var s := get_effective_settings()
	match feature:
		Feature.POM:
			return s.pom_enabled
		Feature.SELF_SHADOW:
			return s.self_shadow != SDSettings.SelfShadow.OFF
		Feature.NEAR_FIELD:
			return s.near_field_enabled
		Feature.DEPTH_WRITE:
			return s.depth_write_enabled
		_:
			return s.scatter_enabled


## The target added GPU time of the current preset (ms), see [method SDSettings.get_budget_ms].
func get_budget_ms() -> float:
	return SDSettings.get_budget_ms(preset if enabled else SDSettings.Preset.OFF)


## Adds [param material] to the materials this node switches (automatic for materials on
## geometry in the scene tree; use it for materials applied later by code).
func register_material(material: Material) -> void:
	if SDMaterials.is_sd_material(material):
		_materials[material.get_instance_id()] = weakref(material)
		if not Engine.is_editor_hint() and is_inside_tree():
			var s := get_effective_settings()
			SDMaterials.set_quality(material, s.get_quality(), s.depth_write_enabled)


## Registers the SD materials of every GeometryInstance3D under [param root].
func register_scene(root: Node) -> void:
	_register_node(root)
	for node in root.find_children("*", "GeometryInstance3D", true, false):
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
	SDGlobals.set_value(SDGlobals.DEBUG, Vector4(debug_view, 0.1, 0.0, 0.0))
	# In the editor only the globals change: materials keep the variant they are saved with, and
	# fields and scatters keep their saved properties (they are scene data).
	if not Engine.is_editor_hint():
		var quality := s.get_quality()
		for m in get_registered_materials():
			SDMaterials.set_quality(m, quality, s.depth_write_enabled)
		for node in get_tree().get_nodes_in_group(&"surface_displacement_field"):
			var field := node as DisplacementField3D
			field.visible = s.near_field_enabled
			field.set_quality(quality)
			if s.near_field_enabled:
				field.levels = s.near_field_levels
				field.resolution = s.near_field_resolution
				field.base_spacing = s.near_field_spacing
		for node in get_tree().get_nodes_in_group(&"surface_displacement_scatter"):
			var scatter_node := node as PebbleScatter3D
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
	if node is GeometryInstance3D:
		_register_node(node)
	elif node is DisplacementField3D or node is PebbleScatter3D:
		_queue_apply()


func _register_node(node: Node) -> void:
	if not node is GeometryInstance3D:
		return
	var gi := node as GeometryInstance3D
	register_material(gi.material_override)
	if gi is MeshInstance3D:
		var mi := gi as MeshInstance3D
		for s in mi.get_surface_override_material_count():
			register_material(mi.get_surface_override_material(s))
		if mi.mesh != null:
			for s in mi.mesh.get_surface_count():
				register_material(mi.mesh.surface_get_material(s))
