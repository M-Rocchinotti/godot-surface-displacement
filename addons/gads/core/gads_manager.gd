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
@export_group("Debug")
@export var debug_view := DebugView.OFF:
	set(value):
		debug_view = value
		_queue_apply()

var _materials := {} # instance id -> WeakRef(ShaderMaterial)
var _apply_queued := false


## The GADSManager node of [param tree], or null.
static func find_in(tree: SceneTree) -> GADSManager:
	var nodes := tree.get_nodes_in_group(&"gads_manager")
	return nodes[0] as GADSManager if not nodes.is_empty() else null


func _enter_tree() -> void:
	add_to_group(&"gads_manager")
	GADSGlobals.ensure_registered()
	if not Engine.is_editor_hint():
		get_tree().node_added.connect(_on_node_added)


func _ready() -> void:
	if not Engine.is_editor_hint():
		register_scene(get_tree().root)
	apply()


func _exit_tree() -> void:
	remove_from_group(&"gads_manager")
	if get_tree().node_added.is_connected(_on_node_added):
		get_tree().node_added.disconnect(_on_node_added)


## The settings in effect: the preset (or [member custom_settings]) with the feature switches and
## [member enabled] applied. A new resource; changing it has no effect.
func get_effective_settings() -> GADSSettings:
	var base: GADSSettings
	if preset == GADSSettings.Preset.CUSTOM and custom_settings != null:
		base = custom_settings.duplicate()
	else:
		base = GADSSettings.create_preset(preset if preset != GADSSettings.Preset.CUSTOM else GADSSettings.Preset.MEDIUM)
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


## The target added GPU time of the current preset (ms), see [method GADSSettings.get_budget_ms].
func get_budget_ms() -> float:
	return GADSSettings.get_budget_ms(preset if enabled else GADSSettings.Preset.OFF)


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
