@tool
@icon("res://addons/gads/icons/gads_mesh_instance_3d.svg")
class_name GADSMeshInstance3D
extends MeshInstance3D
## A mesh whose GADS materials' relief is real geometry: the bake displaces [member source_mesh]
## by the materials' height maps with adaptive tessellation (triangles only where the relief needs
## them), crack-free across UV seams and hard edges, with rebuilt normals and tangents, LODs and an
## optional collision shape at its own resolution.
##
## Non-destructive: [member source_mesh] is never modified. The bake is a file in
## [member cache_directory] named after the inputs' key, so the scene refers to it instead of
## embedding it, and an unchanged mesh is not baked twice. [method is_bake_stale] tells when the
## source, the materials, the settings or (world and triplanar mappings) the placement changed
## since; Bake picks the change up, Clear goes back to the source mesh.
##
## The materials stay the same: on a baked mesh they skip their parallax march, map textures where
## each vertex was before it moved, and take only the normal-map detail finer than the triangles
## (the [code]gads_baked[/code] instance parameter). Debug view Tessellation shows the refinement.
##
## Needs the GADS native library (addons/gads/native/, Linux and Windows x86_64).

signal bake_started
## While a background bake runs: progress 0..1 of the main pass and its triangles so far.
signal bake_progress(progress: float, triangles: int)
signal bake_finished(ok: bool)

enum Quality { DRAFT, LOW, MEDIUM, HIGH, ULTRA, CUSTOM }
## How each vertex moves: AUTO along world +Y when every displaced surface is world-planar (the
## shaders' relief axis there), else along the source's smoothed normal; NORMAL along the smoothed
## normal always; AXIS along [member direction_axis] (world; terrain-like meshes).
enum Direction { AUTO, NORMAL, AXIS }

## Per preset: tolerance as a fraction of the largest relief depth (height_m) of the materials,
## and the triangle budget.
const QUALITY_PRESETS := {
	Quality.DRAFT: [0.05, 25000],
	Quality.LOW: [0.025, 75000],
	Quality.MEDIUM: [0.0125, 200000],
	Quality.HIGH: [0.006, 500000],
	Quality.ULTRA: [0.003, 1500000],
}
const BAKED_PARAMETER := &"gads_baked"

## Whether [member MeshInstance3D.mesh] is the bake (else it is the source mesh). Declared before
## source_mesh so a scene sets it first when it loads.
@export_storage var baked := false

## The mesh to displace. Never modified; Clear shows it again.
@export var source_mesh: Mesh:
	set(value):
		source_mesh = value
		if not baked:
			mesh = value
		update_configuration_warnings()

@export_group("Bake")
## How closely the geometry follows the height maps, and its triangle budget.
@export var quality := Quality.MEDIUM:
	set(value):
		quality = value
		notify_property_list_changed()
## Custom quality: the largest distance (m) the geometry may be from the relief.
@export_range(0.00001, 0.05, 0.00001, "or_greater", "suffix:m") var custom_max_error := 0.0005
## Custom quality: triangle budget (the worst regions are refined first).
@export_range(1000, 5000000, 1000, "or_greater") var custom_max_triangles := 200000
## No edge is split below this many height-map texels.
@export_range(0.25, 16.0, 0.25) var min_edge_texels := 1.0
## Open edges keep their place, so meshes that tile with neighbours still meet.
@export var lock_borders := false
@export var direction := Direction.AUTO:
	set(value):
		direction = value
		notify_property_list_changed()
@export var direction_axis := Vector3.UP
## Source normals further apart than this keep a hard edge.
@export_range(0.0, 180.0, 0.1, "degrees") var hard_angle := 30.0
@export var generate_lods := true
## Where bakes are saved (one file per key; files of earlier bakes are not deleted).
@export_dir var cache_directory := "res://gads_baked"

@export_group("Collision")
## A static body with this shape, made by a coarser pass of its own.
@export var collision := GADSMeshBaker.Collision.NONE:
	set(value):
		collision = value
		notify_property_list_changed()
		_update_collision()
@export_range(100, 1000000, 100, "or_greater") var collision_max_triangles := 20000
## Collision tolerance relative to the render mesh's.
@export_range(1.0, 64.0, 0.5) var collision_error_scale := 4.0
@export_flags_3d_physics var collision_layer := 1:
	set(value):
		collision_layer = value
		_update_collision()
@export_flags_3d_physics var collision_mask := 1:
	set(value):
		collision_mask = value
		_update_collision()

@export_storage var bake_key := ""
## The bake's statistics: source_triangles, triangles, vertices, max_level, budget_reached,
## max_error_left (m), error_m (the tolerance), seconds, collision_triangles, path.
@export_storage var bake_stats := {}
@export_storage var collision_shape: Shape3D

var _baker: GADSMeshBaker
var _pending := {}
var _body: StaticBody3D


func _ready() -> void:
	# _process only polls a background bake (which may have started before the node was ready).
	set_process(is_baking())
	# A MeshInstance3D converted to this type keeps its mesh as the source.
	if source_mesh == null and not baked and mesh != null:
		source_mesh = mesh
	elif not baked and source_mesh != null:
		mesh = source_mesh
	if baked and mesh == null:
		push_warning("GADS: %s lost its baked mesh (%s); showing the source mesh until it is baked again." % [name, bake_stats.get("path", "?")])
		_apply_state({"baked": false})
	_apply_parameter()
	_update_collision()


func _validate_property(property: Dictionary) -> void:
	match property["name"]:
		"mesh":
			# Set source_mesh instead: mesh is the bake or a mirror of the source.
			property["usage"] |= PROPERTY_USAGE_READ_ONLY
		"custom_max_error", "custom_max_triangles":
			if quality != Quality.CUSTOM:
				property["usage"] = PROPERTY_USAGE_STORAGE
		"direction_axis":
			if direction != Direction.AXIS:
				property["usage"] = PROPERTY_USAGE_STORAGE
		"collision_max_triangles", "collision_error_scale", "collision_layer", "collision_mask":
			if collision == GADSMeshBaker.Collision.NONE:
				property["usage"] = PROPERTY_USAGE_STORAGE


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if not GADSMeshBaker.is_available():
		out.append("The GADS native library is not loaded on this platform: the mesh cannot be baked (see README).")
	var problem := GADSMeshBaker.check_mesh(source_mesh)
	if not problem.is_empty():
		out.append("Cannot bake: %s." % problem)
	elif _max_depth() <= 0.0:
		out.append("No surface uses a GADS material with a height map and a height_m above 0: nothing to bake.")
	elif baked and is_bake_stale():
		out.append("The source, the materials, the settings or the placement changed since the bake: bake again.")
	return out


## The tessellation and collision settings the next bake uses (see GADSMeshBaker.setup).
func get_bake_settings() -> Dictionary:
	var tolerance := custom_max_error
	var budget := custom_max_triangles
	if quality != Quality.CUSTOM:
		tolerance = QUALITY_PRESETS[quality][0] * _max_depth()
		budget = QUALITY_PRESETS[quality][1]
	var settings := {
		"max_error": maxf(tolerance, 1e-6),
		"max_triangles": budget,
		"min_edge_texels": min_edge_texels,
		"lock_borders": lock_borders,
		"direction_mode": direction,
		"hard_angle_deg": hard_angle,
		"lods": generate_lods,
	}
	if direction == Direction.AXIS:
		settings["direction"] = direction_axis.normalized()
	if collision != GADSMeshBaker.Collision.NONE:
		settings["collision"] = collision
		settings["collision_max_triangles"] = collision_max_triangles
		settings["collision_error_scale"] = collision_error_scale
	return settings


## The key of a bake of the current inputs (the cache file name holds its start).
func compute_bake_key() -> String:
	return GADSMeshBaker.cache_key(source_mesh, _materials(), _bake_transform(), get_bake_settings())


func is_bake_stale() -> bool:
	return baked and bake_key != compute_bake_key()


func is_baking() -> bool:
	return _baker != null


## Bakes on the calling thread. [param force]: bake even when the cache has this key.
## Returns OK, ERR_UNAVAILABLE without the native library, ERR_BUSY during a background bake or
## FAILED (nothing to displace, or see the warning printed).
func bake(force := false) -> Error:
	var err := _begin(force)
	if err != OK or _baker == null:
		return err
	var ok := _baker.run()
	return OK if _complete(ok) else FAILED


## Starts a background bake; bake_progress and bake_finished follow.
func bake_async(force := false) -> Error:
	var err := _begin(force)
	if err != OK or _baker == null:
		return err
	if not _baker.start():
		_complete(false)
		return FAILED
	set_process(true)
	return OK


func cancel_bake() -> void:
	if _baker != null:
		_baker.cancel()


## Shows the source mesh again (the cached bake files stay).
func clear_bake() -> void:
	cancel_bake()
	_apply_state({"baked": false})


## The state a bake sets (for undo and redo in the editor).
func get_bake_state() -> Dictionary:
	return {"baked": baked, "mesh": mesh if baked else null, "bake_key": bake_key, "bake_stats": bake_stats.duplicate(),
		"collision_shape": collision_shape}


func set_bake_state(state: Dictionary) -> void:
	_apply_state(state)


## The bake's statistics in a few lines (the inspector shows them).
func get_bake_summary() -> String:
	if not baked:
		return "Not baked."
	var s := bake_stats
	var lines: Array[String] = []
	lines.append("%s%s triangles (source %s), %s vertices." % ["STALE, bake again. " if is_bake_stale() else "",
		_count(s.get("triangles", 0)), _count(s.get("source_triangles", 0)), _count(s.get("vertices", 0))])
	var budget := ""
	if s.get("budget_reached", false):
		budget = " Budget reached, up to %.2f mm off." % (float(s.get("max_error_left", 0.0)) * 1000.0)
	lines.append("Tolerance %.3f mm, %d levels.%s" % [float(s.get("error_m", 0.0)) * 1000.0, s.get("max_level", 0), budget])
	if s.has("collision_triangles"):
		lines.append("Collision: %s triangles." % _count(s["collision_triangles"]))
	var where: String = s.get("path", "in memory (not saved)")
	if s.get("cached", false):
		lines.append("From the cache: %s" % where)
	else:
		lines.append("Baked in %.1f s: %s" % [float(s.get("seconds", 0.0)), where])
	return "\n".join(lines)


static func _count(n: int) -> String:
	if n >= 1000000:
		return "%.2f M" % (n / 1e6)
	if n >= 10000:
		return "%.1f k" % (n / 1e3)
	return str(n)


func _process(_delta: float) -> void:
	if _baker == null:
		set_process(false)
		return
	if not _baker.is_done():
		bake_progress.emit(_baker.get_progress(), _baker.get_triangle_count())
		return
	set_process(false)
	_complete(_baker.finish())


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _baker != null:
		_baker.cancel()
		_baker.finish()


func _materials() -> Array[Material]:
	return GADSMeshBaker.resolve_materials(self, source_mesh)


func _bake_transform() -> Transform3D:
	return global_transform if is_inside_tree() else transform


## The largest relief depth among the surfaces the bake displaces (0: none).
func _max_depth() -> float:
	var depth := 0.0
	for m in _materials():
		var d := GADSMeshBaker.displacement_of(m)
		if not d.is_empty():
			depth = maxf(depth, d["height_m"])
			for layer: Dictionary in d["layers"]:
				if layer["amount"] > 0.0:
					depth = maxf(depth, layer["height_m"])
	return depth


func _cache_paths(key: String) -> Array[String]:
	var stem := source_mesh.resource_path.get_file().get_basename().get_slice("::", 0) if source_mesh != null else ""
	if stem.is_empty():
		stem = String(name).to_snake_case()
	stem = stem.validate_filename().replace(" ", "_")
	var base := cache_directory.path_join("%s_%s" % [stem, key.left(16)])
	var collision_path := ""
	if collision != GADSMeshBaker.Collision.NONE:
		collision_path = base + "_collision.res"
	return [base + ".mesh", collision_path]


## Sets up _baker, or applies a cached bake (then _baker stays null and _pending holds the state).
func _begin(force: bool) -> Error:
	if _baker != null:
		return ERR_BUSY
	_pending = {}
	if not GADSMeshBaker.is_available():
		push_warning("GADS: %s: the native library is not loaded; cannot bake." % name)
		return ERR_UNAVAILABLE
	if _max_depth() <= 0.0:
		push_warning("GADS: %s: no surface uses a GADS material with a height map and a height_m above 0; nothing to bake." % name)
		return FAILED
	var key := compute_bake_key()
	var paths := _cache_paths(key)
	if not force and ResourceLoader.exists(paths[0]) and (paths[1].is_empty() or ResourceLoader.exists(paths[1])):
		var cached := ResourceLoader.load(paths[0]) as ArrayMesh
		var shape := ResourceLoader.load(paths[1]) as Shape3D if not paths[1].is_empty() else null
		if cached != null and (paths[1].is_empty() or shape != null):
			var stats: Dictionary = cached.get_meta("gads_bake", {}).duplicate()
			stats["path"] = paths[0]
			stats["cached"] = true
			_pending = {"baked": true, "mesh": cached, "bake_key": key, "bake_stats": stats, "collision_shape": shape}
			bake_started.emit()
			_apply_state(_pending)
			bake_finished.emit(true)
			return OK
	_baker = GADSMeshBaker.new()
	_baker.setup(source_mesh, _materials(), _bake_transform(), get_bake_settings())
	_pending = {"bake_key": key, "paths": paths}
	bake_started.emit()
	return OK


func _complete(ok: bool) -> bool:
	var baker := _baker
	_baker = null
	if not ok:
		if baker.error != "cancelled":
			push_warning("GADS: %s: bake failed: %s" % [name, baker.error])
		bake_finished.emit(false)
		return false
	var paths: Array[String] = _pending["paths"]
	var result := baker.mesh
	var shape := baker.collision_shape
	var stats := baker.stats.duplicate()
	if _save(result, paths[0]):
		stats["path"] = paths[0]
		if shape != null:
			_save(shape, paths[1])
	_apply_state({"baked": true, "mesh": result, "bake_key": _pending["bake_key"], "bake_stats": stats, "collision_shape": shape})
	bake_finished.emit(true)
	return true


## Saves into the cache directory and makes [param res] the resource of that path, so the scene
## refers to the file. A bake made while the game runs is not saved into res:// (read-only in an
## exported game, and a running game should not edit the project): it lives in memory only,
## unless cache_directory points elsewhere (user://).
func _save(res: Resource, path: String) -> bool:
	if path.begins_with("res://") and not Engine.is_editor_hint():
		return false
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var err := ResourceSaver.save(res, path)
	if err != OK:
		push_warning("GADS: cannot save %s (%s); the bake is kept in the scene." % [path, error_string(err)])
		return false
	res.take_over_path(path)
	if Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
		var fs: Object = Engine.get_singleton("EditorInterface").call("get_resource_filesystem")
		fs.call("update_file", path)
	return true


func _apply_state(state: Dictionary) -> void:
	baked = state.get("baked", false)
	bake_key = state.get("bake_key", "") if baked else ""
	bake_stats = state.get("bake_stats", {}) if baked else {}
	collision_shape = state.get("collision_shape") if baked else null
	mesh = state.get("mesh") if baked else source_mesh
	_apply_parameter()
	_update_collision()
	update_configuration_warnings()
	notify_property_list_changed()


func _apply_parameter() -> void:
	set_instance_shader_parameter(BAKED_PARAMETER, 1.0 if baked else null)


## A static body (internal child: not saved, not in the scene tree dock) with the baked shape.
func _update_collision() -> void:
	if not is_inside_tree():
		return
	var want := baked and collision_shape != null and collision != GADSMeshBaker.Collision.NONE
	if not want:
		if _body != null:
			_body.queue_free()
			_body = null
		return
	if _body == null:
		_body = StaticBody3D.new()
		_body.name = "GADSCollision"
		var cs := CollisionShape3D.new()
		_body.add_child(cs)
		add_child(_body, false, Node.INTERNAL_MODE_BACK)
	_body.collision_layer = collision_layer
	_body.collision_mask = collision_mask
	(_body.get_child(0) as CollisionShape3D).shape = collision_shape
