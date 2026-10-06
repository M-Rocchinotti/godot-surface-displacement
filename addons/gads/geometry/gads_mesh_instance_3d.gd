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
## A runtime (view-dependent) tessellation replaced the mesh; [param stats] as [member view_stats].
signal view_tessellated(stats: Dictionary)

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
## Splits the bake into clusters of at most this many triangles, each drawn as its own instance:
## the engine culls them and picks LODs per cluster, so a large mesh (a cliff, a facade, a terrain
## patch) is detailed only where the camera is close. 0: one mesh.
@export_range(0, 1000000, 1000, "or_greater") var cluster_triangles := 0
## Where bakes are saved (one file per key; files of earlier bakes are not deleted).
@export_dir var cache_directory := "res://gads_baked"

@export_group("Distance")
## Beyond this distance (m) the source mesh is drawn with the materials' parallax instead of the
## baked geometry, cross-faded over geometry_range_margin on either side: geometry near the camera,
## parallax further out, plain normal mapping beyond the presets' fade. 0: geometry at every
## distance. [method suggest_geometry_range] gives the distance where the relief shrinks below a
## couple of pixels. While it is set, the node uses its own visibility range.
@export_range(0.0, 1000.0, 0.1, "or_greater", "suffix:m") var geometry_range := 0.0:
	set(value):
		geometry_range = value
		_update_fallback()
@export_range(0.0, 50.0, 0.1, "or_greater", "suffix:m") var geometry_range_margin := 2.0:
	set(value):
		geometry_range_margin = value
		_update_fallback()

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

@export_group("Runtime")
## While the game runs, tessellate again in the background as the camera moves: dense where the
## camera looks closely, coarser with distance, so the error stays under [member pixel_error]
## pixels on screen (the quality's tolerance is the finest it goes). The editor bake, if any, shows
## until the first runtime mesh is ready; the collision shape stays the editor bake's. For meshes
## the camera gets close to and far from (terrain patches, large rocks); small props are better
## off with a fixed bake and LODs.
@export var view_dependent := false:
	set(value):
		view_dependent = value
		_update_view_processing()
## The error on screen the runtime tessellation keeps (pixels).
@export_range(0.1, 16.0, 0.1, "suffix:px") var pixel_error := 1.0
## Tessellate again once the camera moved this fraction of its distance to the mesh.
@export_range(0.01, 2.0, 0.01) var view_refresh := 0.25
## The triangle budget of a runtime tessellation.
@export_range(1000, 5000000, 1000, "or_greater") var view_max_triangles := 150000
## The camera to follow; empty = the viewport's current camera.
@export var view_camera: NodePath

@export_storage var bake_key := ""
## The bake's statistics: source_triangles, triangles, vertices, max_level, budget_reached,
## max_error_left (m), error_m (the tolerance), seconds, collision_triangles, path.
@export_storage var bake_stats := {}
@export_storage var collision_shape: Shape3D

var _baker: GADSMeshBaker
var _pending := {}
var _body: StaticBody3D
var _fallback: MeshInstance3D
var _owns_visibility_range := false
## The last runtime tessellation's statistics (as bake_stats, plus view_position).
var view_stats := {}
var _view_baker: GADSMeshBaker
var _view_mesh: ArrayMesh
var _static_mesh: Mesh # what mesh was before the first runtime mesh replaced it
var _view_eye := Vector3.INF
var _view_focal := 0.0
var _view_xform := Transform3D()
var _view_images := {}
var _cluster_nodes: Array[MeshInstance3D] = []
var _cluster_snapshot := []
var _hlod := false # the node and its clusters show while the fallback is hidden


func _ready() -> void:
	# _process polls a background bake (which may have started before the node was ready) and
	# follows the camera for the runtime tessellation.
	set_process(is_baking() or _view_running())
	_sync_clusters()
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
	_update_fallback()


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
	if cluster_triangles > 0:
		settings["cluster_triangles"] = cluster_triangles
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
	var shown := _static_mesh if _view_mesh != null else mesh
	return {"baked": baked, "mesh": shown if baked else null, "bake_key": bake_key, "bake_stats": bake_stats.duplicate(),
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
	if _baker != null:
		if _baker.is_done():
			_complete(_baker.finish())
		else:
			bake_progress.emit(_baker.get_progress(), _baker.get_triangle_count())
	if not _cluster_nodes.is_empty() and _draw_snapshot() != _cluster_snapshot:
		_sync_clusters()
		_update_fallback()
	if _view_running():
		_update_view()
	elif _baker == null and _cluster_nodes.is_empty():
		set_process(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		for b: GADSMeshBaker in [_baker, _view_baker]:
			if b != null:
				b.cancel()
				b.finish()


func _materials() -> Array[Material]:
	return GADSMeshBaker.resolve_materials(self, source_mesh)


func _bake_transform() -> Transform3D:
	return global_transform if is_inside_tree() else transform


## The deepest relief (m) the materials give the source mesh: the main depth or a deeper layer's
## (0: nothing to displace).
func get_relief_depth() -> float:
	return _max_depth()


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
	# A runtime mesh made from the old state is dropped (the next one follows the new state).
	_cancel_view_baker()
	_drop_view_mesh()
	baked = state.get("baked", false)
	bake_key = state.get("bake_key", "") if baked else ""
	bake_stats = state.get("bake_stats", {}) if baked else {}
	collision_shape = state.get("collision_shape") if baked else null
	mesh = state.get("mesh") if baked else source_mesh
	_apply_parameter()
	_update_collision()
	_sync_clusters()
	_update_fallback()
	update_configuration_warnings()
	notify_property_list_changed()


func _apply_parameter() -> void:
	set_instance_shader_parameter(BAKED_PARAMETER, 1.0 if baked or _view_mesh != null else null)


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


## The distance (m) where the deepest relief of the materials covers [param pixels] pixels on a
## screen [param screen_height] pixels high with a vertical field of view of [param fov_deg]:
## beyond it the baked geometry adds little over parallax.
func suggest_geometry_range(pixels := 2.0, screen_height := 1080.0, fov_deg := 70.0) -> float:
	var depth := _max_depth()
	if depth <= 0.0:
		return 0.0
	return depth * screen_height / (2.0 * tan(deg_to_rad(fov_deg) * 0.5) * pixels)


## The node that draws the source mesh with parallax beyond geometry_range (an internal child),
## or null.
func get_fallback() -> MeshInstance3D:
	return _fallback


## Beyond geometry_range: an internal child draws the source mesh (the materials then march, as
## gads_baked is not set on it), and the two cross-fade through their visibility ranges.
func _update_fallback() -> void:
	if not is_inside_tree():
		return
	var want := (baked or _view_mesh != null) and geometry_range > 0.0 and source_mesh != null
	if not want:
		if _fallback != null:
			_fallback.queue_free()
			_fallback = null
		if _owns_visibility_range:
			visibility_range_end = 0.0
			visibility_range_end_margin = 0.0
			visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
			_owns_visibility_range = false
		_update_cluster_visibility()
		return
	if _fallback == null:
		_fallback = MeshInstance3D.new()
		_fallback.name = "GADSParallaxFallback"
		add_child(_fallback, false, Node.INTERNAL_MODE_BACK)
	_fallback.mesh = source_mesh
	_fallback.material_override = material_override
	_fallback.material_overlay = material_overlay
	for s in get_surface_override_material_count():
		if s < _fallback.get_surface_override_material_count():
			_fallback.set_surface_override_material(s, get_surface_override_material(s))
	_fallback.cast_shadow = cast_shadow
	_fallback.layers = layers
	_fallback.visibility_range_begin = geometry_range
	_fallback.visibility_range_begin_margin = geometry_range_margin
	_fallback.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	_owns_visibility_range = true
	if _cluster_nodes.is_empty():
		visibility_range_end = geometry_range
		visibility_range_end_margin = geometry_range_margin
		visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	else:
		# Clusters each measure the distance to their own centre: instead they all show while the
		# fallback (the whole source mesh) is hidden by its range, one distance for all (HLOD).
		visibility_range_end = 0.0
		visibility_range_end_margin = 0.0
		visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	_update_cluster_visibility()


# --- Clusters ------------------------------------------------------------------------------------

## Draw settings the cluster instances copy from the node (checked each frame while there are
## clusters; the visibility settings follow in _update_cluster_visibility()).
const CLUSTER_SYNCED: Array[StringName] = [&"material_override", &"material_overlay", &"cast_shadow", &"layers", &"gi_mode",
	&"lod_bias", &"transparency", &"extra_cull_margin", &"visibility_range_begin", &"visibility_range_end",
	&"visibility_range_begin_margin", &"visibility_range_end_margin", &"visibility_range_fade_mode", &"visibility_parent"]


## The other clusters of a clustered bake (the first is [param m] itself), from its metadata.
static func cluster_meshes_of(m: Mesh) -> Array:
	return m.get_meta(&"gads_clusters", []) if m != null else []


## How many instances draw the mesh: 1, or the clusters of a clustered bake (see
## [member cluster_triangles]).
func get_cluster_count() -> int:
	return 1 + _cluster_nodes.size()


## The internal children that draw a clustered bake's other clusters.
func get_cluster_nodes() -> Array[MeshInstance3D]:
	return _cluster_nodes


func _draw_snapshot() -> Array:
	var out := []
	for p in CLUSTER_SYNCED:
		out.append(get(p))
	for s in get_surface_override_material_count():
		out.append(get_surface_override_material(s))
	return out


## One internal MeshInstance3D per cluster beyond the first, drawing like the node.
func _sync_clusters() -> void:
	var meshes: Array = cluster_meshes_of(mesh) if baked or _view_mesh != null else []
	while _cluster_nodes.size() > meshes.size():
		_cluster_nodes.pop_back().queue_free()
	while _cluster_nodes.size() < meshes.size():
		var mi := MeshInstance3D.new()
		mi.name = "GADSCluster%d" % (_cluster_nodes.size() + 2)
		add_child(mi, false, Node.INTERNAL_MODE_BACK)
		_cluster_nodes.append(mi)
	for i in meshes.size():
		var mi := _cluster_nodes[i]
		mi.mesh = meshes[i]
		for p in CLUSTER_SYNCED:
			if not String(p).begins_with("visibility"):
				mi.set(p, get(p))
		for s in mini(get_surface_override_material_count(), mi.get_surface_override_material_count()):
			mi.set_surface_override_material(s, get_surface_override_material(s))
		mi.set_instance_shader_parameter(BAKED_PARAMETER, 1.0)
	_update_cluster_visibility()
	if not _cluster_nodes.is_empty() and is_inside_tree():
		set_process(true)


## Clusters show and hide with the node: by its own visibility range, or (with a geometry range)
## all together by the fallback's. The fallback link is set on the rendering instances directly:
## a node's visibility_parent would also apply to its children, the fallback among them.
func _update_cluster_visibility() -> void:
	var parent := get_node_or_null(visibility_parent) if not visibility_parent.is_empty() else null
	for mi in _cluster_nodes:
		mi.visibility_range_begin = visibility_range_begin
		mi.visibility_range_end = visibility_range_end
		mi.visibility_range_begin_margin = visibility_range_begin_margin
		mi.visibility_range_end_margin = visibility_range_end_margin
		mi.visibility_range_fade_mode = visibility_range_fade_mode
		mi.visibility_parent = mi.get_path_to(parent) if parent != null else NodePath()
	var hlod := _owns_visibility_range and _fallback != null and not _cluster_nodes.is_empty()
	if hlod or _hlod:
		var target := _fallback.get_instance() if hlod else RID()
		RenderingServer.instance_set_visibility_parent(get_instance(), target)
		for mi in _cluster_nodes:
			RenderingServer.instance_set_visibility_parent(mi.get_instance(), target)
		_hlod = hlod
	_cluster_snapshot = _draw_snapshot()


## The rendering instances that show while the fallback is hidden (see _update_cluster_visibility()).
func get_fallback_dependents() -> Array[RID]:
	var out: Array[RID] = []
	if _hlod:
		out.append(get_instance())
		for mi in _cluster_nodes:
			out.append(mi.get_instance())
	return out


# --- Runtime (view-dependent) tessellation ------------------------------------------------------

## Tessellates for the current camera again on the next frame (with view_dependent, while the
## game runs), e.g. after a teleport or a change of the materials.
func refresh_view() -> void:
	_view_eye = Vector3.INF
	_update_view_processing()


## Whether a runtime tessellation runs in the background.
func is_view_tessellating() -> bool:
	return _view_baker != null


func _view_running() -> bool:
	return view_dependent and not Engine.is_editor_hint() and is_inside_tree() and source_mesh != null


func _update_view_processing() -> void:
	if _view_running():
		set_process(true)
	elif _view_baker != null or _view_mesh != null:
		_cancel_view_baker()
		_drop_view_mesh()
		_apply_parameter()
		_update_fallback()


func _cancel_view_baker() -> void:
	if _view_baker != null:
		_view_baker.cancel()
		_view_baker.finish()
		_view_baker = null


## Shows the mesh from before the runtime tessellation again.
func _drop_view_mesh() -> void:
	if _view_mesh != null:
		_view_mesh = null
		mesh = _static_mesh
		_static_mesh = null
		_sync_clusters()
	_view_eye = Vector3.INF


func _view_camera_node() -> Camera3D:
	if not view_camera.is_empty():
		return get_node_or_null(view_camera) as Camera3D
	return get_viewport().get_camera_3d() if get_viewport() != null else null


## Pixels per radian at the centre of the camera's view.
static func _focal_px(cam: Camera3D) -> float:
	var size := cam.get_viewport().get_visible_rect().size
	var extent := size.x if cam.keep_aspect == Camera3D.KEEP_WIDTH else size.y
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return extent / maxf(cam.size, 1e-6) # pixels per metre
	return extent / (2.0 * tan(deg_to_rad(cam.fov) * 0.5))


func _update_view() -> void:
	if _view_baker != null:
		if _view_baker.is_done():
			_finish_view()
		return
	var cam := _view_camera_node()
	if cam == null or not GADSMeshBaker.is_available():
		return
	var eye := cam.global_position
	var focal := _focal_px(cam)
	if _view_eye != Vector3.INF:
		var aabb := global_transform * source_mesh.get_aabb()
		var dist := maxf(_aabb_distance(aabb, _view_eye), maxf(aabb.get_longest_axis_size() * 0.02, 0.05))
		var moved := eye.distance_to(_view_eye) > view_refresh * dist
		var zoomed := absf(focal - _view_focal) > 0.25 * _view_focal
		if not moved and not zoomed and global_transform.is_equal_approx(_view_xform):
			return
	_start_view(cam, eye, focal)


static func _aabb_distance(aabb: AABB, p: Vector3) -> float:
	var q := p.clamp(aabb.position, aabb.end)
	return p.distance_to(q)


func _start_view(cam: Camera3D, eye: Vector3, focal: float) -> void:
	_view_eye = eye
	_view_focal = focal
	_view_xform = global_transform
	if _max_depth() <= 0.0:
		return
	var settings := get_bake_settings()
	settings.erase("collision")
	settings["lods"] = false
	settings["max_triangles"] = view_max_triangles
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		settings["max_error"] = maxf(settings["max_error"], pixel_error / focal)
	else:
		settings["view_dependent"] = true
		settings["view_position"] = eye
		settings["pixel_error"] = pixel_error
		settings["focal_px"] = focal
	_view_baker = GADSMeshBaker.new()
	_view_baker.image_cache = _view_images
	_view_baker.setup(source_mesh, _materials(), _bake_transform(), settings)
	if not _view_baker.start():
		push_warning("GADS: %s: runtime tessellation failed: %s" % [name, _view_baker.error])
		_view_baker = null


func _finish_view() -> void:
	var baker := _view_baker
	_view_baker = null
	if not baker.finish():
		if baker.error != "cancelled":
			push_warning("GADS: %s: runtime tessellation failed: %s" % [name, baker.error])
		return
	if _view_mesh == null:
		_static_mesh = mesh
	_view_mesh = baker.mesh
	view_stats = baker.stats.duplicate()
	view_stats["view_position"] = _view_eye
	mesh = _view_mesh
	_apply_parameter()
	_sync_clusters()
	_update_fallback()
	view_tessellated.emit(view_stats)
