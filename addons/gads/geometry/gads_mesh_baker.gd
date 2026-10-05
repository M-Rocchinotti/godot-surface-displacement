@tool
class_name GADSMeshBaker
extends RefCounted
## Bakes the relief of GADS materials into a mesh's geometry with the native adaptive tessellator
## (GADSTessellator, native/): the triangles are refined only where the height field needs them,
## crack-free across UV seams and hard edges, and the result carries rebuilt normals and tangents
## plus the rest data the GADS shaders read on a baked mesh (see gads_core.gdshaderinc). An optional
## second, coarser pass makes the collision shape.
##
## [codeblock]
## var baker := GADSMeshBaker.new()
## baker.setup(mesh, materials, global_transform, {"max_error": 0.0005, "max_triangles": 200000})
## if baker.run():                 # blocking; or start() + is_done() + finish() for a background bake
##     mesh_instance.mesh = baker.mesh
## [/codeblock]
##
## [GADSMeshInstance3D] wraps this with a cache, a non-destructive source mesh and editor buttons.

## Bump when the GDScript side changes what a bake produces (the native library has its own).
const PIPELINE_VERSION := 1
const NATIVE_CLASS := "GADSTessellator"

enum Collision { NONE, TRIMESH, CONVEX }

## The baked mesh (after a successful run() or finish()).
var mesh: ArrayMesh
## The collision shape, or null when no collision was asked for.
var collision_shape: Shape3D
## Tessellator statistics plus "error_m", "seconds" and "collision_triangles".
var stats := {}
## Why the last bake failed ("" after a success).
var error := ""

var _source: Mesh
var _materials: Array[Material] = []
var _transform := Transform3D.IDENTITY
var _settings := {}
var _tess: RefCounted
var _collision_tess: RefCounted
var _task := -1
var _importer: ImporterMesh
var _collision_faces := PackedVector3Array()
var _ok := false
var _started_ms := 0
var _cancelled := false


## Whether the native library is loaded (it ships for Linux and Windows x86_64; see README).
static func is_available() -> bool:
	return ClassDB.class_exists(NATIVE_CLASS)


## The material each surface of [param mesh] draws with on [param node] (override, then surface
## override, then the mesh's own), as the bake resolves it.
static func resolve_materials(node: GeometryInstance3D, mesh: Mesh) -> Array[Material]:
	var out: Array[Material] = []
	if mesh == null:
		return out
	for s in mesh.get_surface_count():
		var m: Material = node.material_override if node != null else null
		if m == null and node is MeshInstance3D and s < (node as MeshInstance3D).get_surface_override_material_count():
			m = (node as MeshInstance3D).get_surface_override_material(s)
		if m == null:
			m = mesh.surface_get_material(s)
		out.append(m)
	return out


## The displacement a GADS material applies ({} when it applies none): the tessellator's
## parameter dictionary without the height map index.
static func displacement_of(material: Material) -> Dictionary:
	if not GADSMaterials.is_gads_material(material):
		return {}
	var sm := material as ShaderMaterial
	var height := sm.get_shader_parameter("height_texture") as Texture2D
	var height_m: float = GADSMaterials.get_param(sm, "height_m")
	if height == null or height_m <= 0.0:
		return {}
	return {
		"texture": height,
		"mapping": GADSMaterials.parse(sm.shader)["mapping"],
		"height_m": height_m,
		"center": GADSMaterials.get_param(sm, "height_center"),
		"remap": GADSMaterials.get_param(sm, "height_remap"),
		"uv_scale": GADSMaterials.get_param(sm, "uv_scale"),
		"uv_offset": GADSMaterials.get_param(sm, "uv_offset"),
		"texture_size_m": GADSMaterials.get_param(sm, "texture_size_m"),
		"rotation_deg": GADSMaterials.get_param(sm, "planar_rotation_deg"),
		"planar_offset_m": GADSMaterials.get_param(sm, "planar_offset_m"),
		"triplanar_sharpness": GADSMaterials.get_param(sm, "triplanar_sharpness"),
		"detail_texture": sm.get_shader_parameter("detail_height_texture") as Texture2D,
		"detail_height_m": GADSMaterials.get_param(sm, "detail_height_m"),
		"detail_scale": GADSMaterials.get_param(sm, "detail_scale"),
	}


## Why [param mesh] cannot be baked, or "" when it can.
static func check_mesh(mesh: Mesh) -> String:
	if mesh == null:
		return "no source mesh"
	if mesh.get_surface_count() == 0:
		return "the source mesh has no surfaces"
	for s in mesh.get_surface_count():
		if surface_primitive(mesh, s) != Mesh.PRIMITIVE_TRIANGLES:
			return "surface %d is not made of triangles" % s
		var arrays := mesh.surface_get_arrays(s)
		if arrays[Mesh.ARRAY_BONES] != null:
			return "skinned meshes are not supported (surface %d has bone weights)" % s
	return ""


## The primitive type of a surface of any Mesh (only ArrayMesh has a method for it).
static func surface_primitive(mesh: Mesh, surface: int) -> int:
	if mesh is ArrayMesh:
		return (mesh as ArrayMesh).surface_get_primitive_type(surface)
	return RenderingServer.mesh_get_surface(mesh.get_rid(), surface).get("primitive", Mesh.PRIMITIVE_TRIANGLES)


## A key that changes whenever anything that shapes the bake changes: the source mesh, the
## displacement of each surface (material parameters and height map contents), the transform where
## it matters (all of it for world and triplanar mappings, the basis for UV mapping, since the
## error is measured in metres), the settings and both pipelines' versions.
static func cache_key(mesh: Mesh, materials: Array[Material], xform: Transform3D, settings: Dictionary) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var parts: Array = [PIPELINE_VERSION, native_version(), _resource_id(mesh)]
	var planar := false
	for m in materials:
		var d := displacement_of(m)
		if not d.is_empty():
			planar = planar or d["mapping"] != GADSMaterials.Mapping.UV
			d["texture"] = _resource_id(d["texture"])
			d["detail_texture"] = _resource_id(d["detail_texture"])
		parts.append(d)
	var b := xform.basis
	var basis_values := [b.x, b.y, b.z]
	parts.append(_rounded(basis_values))
	if planar:
		parts.append(_rounded([xform.origin]))
	var keys := settings.keys()
	keys.sort()
	for k in keys:
		parts.append([k, _rounded([settings[k]]) if settings[k] is float or settings[k] is Vector3 else settings[k]])
	ctx.update(var_to_bytes(parts))
	return ctx.finish().hex_encode()


## The native library's algorithm version and build, or "" without it.
static func native_version() -> String:
	if not is_available():
		return ""
	return "%d-%s" % [ClassDB.class_call_static(NATIVE_CLASS, "get_algorithm_version"), ClassDB.class_call_static(NATIVE_CLASS, "get_build_hash")]


static func _rounded(values: Array) -> Array:
	var out := []
	for v: Variant in values:
		if v is Vector3:
			var vec: Vector3 = v
			out.append(Vector3i((vec * 1e4).round()))
		elif v is float:
			out.append(roundi(v * 1e7))
		else:
			out.append(v)
	return out


## An imported asset (or a part of one, like a mesh of a glTF scene) is identified by its path
## and the modification times of its source file and import settings, so an edit or a re-import is
## a change; a resource file of its own by its path and time; a built-in resource (saved inside a
## scene, which changes with every save of the scene) by its contents.
static func _resource_id(res: Resource) -> String:
	if res == null:
		return "null"
	var path := res.resource_path
	var file := path.get_slice("::", 0)
	if not file.is_empty() and FileAccess.file_exists(file + ".import"):
		return "%s@%d/%d" % [path, FileAccess.get_modified_time(file), FileAccess.get_modified_time(file + ".import")]
	if not path.is_empty() and not path.contains("::"):
		return "%s@%d" % [path, FileAccess.get_modified_time(path)]
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	if res is Mesh:
		var mesh := res as Mesh
		for s in mesh.get_surface_count():
			ctx.update(var_to_bytes(mesh.surface_get_arrays(s)))
	elif res is Texture2D:
		var img := (res as Texture2D).get_image()
		if img != null:
			ctx.update(var_to_bytes([img.get_width(), img.get_height(), img.get_format()]))
			ctx.update(img.get_data())
	else:
		ctx.update(var_to_bytes(res))
	return ctx.finish().hex_encode()


## [param settings]: the tessellator's (see native/src/tess/tessellator.h, Settings) plus
## "collision" (Collision), "collision_max_triangles" and "collision_error_scale" (the collision
## pass's tolerance relative to the render pass's), "lods" (bool) and "lod_normal_merge_angle".
func setup(source: Mesh, materials: Array[Material], xform: Transform3D, settings: Dictionary) -> void:
	_source = source
	_materials = materials
	_transform = xform
	_settings = settings


## Starts the bake on a worker thread; poll is_done() / get_progress() and call finish() once it is
## done. Returns false (see error) when the inputs cannot be baked.
func start() -> bool:
	if not _prepare():
		return false
	_task = WorkerThreadPool.add_task(_work, false, "GADS mesh bake")
	return true


## Bakes on the calling thread.
func run() -> bool:
	if not _prepare():
		return false
	_work()
	return finish()


func is_done() -> bool:
	return _task < 0 or WorkerThreadPool.is_task_completed(_task)


## 0..1 over the render pass (the collision pass and the LODs follow it).
func get_progress() -> float:
	return _tess.call("get_progress") if _tess != null else 0.0


## Triangles of the render pass so far.
func get_triangle_count() -> int:
	return _tess.call("get_triangle_count") if _tess != null else 0


func cancel() -> void:
	_cancelled = true
	for t: RefCounted in [_tess, _collision_tess]:
		if t != null:
			t.call("cancel")


## Completes a bake on the main thread (builds the mesh and the shape). Returns whether it worked.
func finish() -> bool:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if _tess == null:
		return false
	if not _ok:
		var native_error: String = _tess.call("get_error")
		error = "cancelled" if _cancelled else (native_error if not native_error.is_empty() else "the tessellator failed")
		_release()
		return false
	mesh = _importer.get_mesh()
	mesh.resource_name = (_source.resource_name if not _source.resource_name.is_empty() else "mesh") + " (GADS baked)"
	match int(_settings.get("collision", Collision.NONE)):
		Collision.TRIMESH:
			var shape := ConcavePolygonShape3D.new()
			shape.set_faces(_collision_faces)
			collision_shape = shape
		Collision.CONVEX:
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = _collision_faces
			var soup := ArrayMesh.new()
			soup.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			collision_shape = soup.create_convex_shape(true, false)
	stats["seconds"] = (Time.get_ticks_msec() - _started_ms) / 1000.0
	mesh.set_meta("gads_bake", stats.duplicate())
	error = ""
	_release()
	return true


func _release() -> void:
	_tess = null
	_collision_tess = null
	_importer = null
	_collision_faces = PackedVector3Array()


func _prepare() -> bool:
	error = ""
	_cancelled = false
	_ok = false
	mesh = null
	collision_shape = null
	stats = {}
	if not is_available():
		error = "the GADS native library is not loaded (addons/gads/native/; see README, Baked displacement)"
		return false
	error = check_mesh(_source)
	if not error.is_empty():
		return false
	_started_ms = Time.get_ticks_msec()
	var max_error: float = _settings.get("max_error", 0.0005)
	_tess = _make_tessellator(_settings)
	if _tess == null:
		return false
	if int(_settings.get("collision", Collision.NONE)) != Collision.NONE:
		var cs := _settings.duplicate()
		cs["max_error"] = max_error * float(_settings.get("collision_error_scale", 4.0))
		cs["max_triangles"] = int(_settings.get("collision_max_triangles", 20000))
		cs["geometry_normals"] = false
		_collision_tess = _make_tessellator(cs)
		if _collision_tess == null:
			return false
	stats["error_m"] = max_error
	return true


func _make_tessellator(settings: Dictionary) -> RefCounted:
	var tess := ClassDB.instantiate(NATIVE_CLASS) as RefCounted
	var maps := {}
	for s in _source.get_surface_count():
		var d := displacement_of(_materials[s] if s < _materials.size() else null)
		if not d.is_empty():
			for key: String in ["texture", "detail_texture"]:
				var tex: Texture2D = d[key]
				d.erase(key)
				if tex == null:
					continue
				if not maps.has(tex):
					var img := tex.get_image()
					if img == null or img.is_empty():
						error = "cannot read the height map %s" % tex.resource_path
						return null
					maps[tex] = tess.call("add_height_map", img)
				d["height_map" if key == "texture" else "detail_height_map"] = maps[tex]
		tess.call("add_surface", _source.surface_get_arrays(s), d)
	tess.call("set_transform", _transform)
	var native_settings := {}
	for k: String in ["max_error", "min_edge_texels", "max_triangles", "max_level", "lock_borders", "weld_distance",
			"direction_mode", "direction", "geometry_normals", "hard_angle_deg", "filter_heights", "threads"]:
		if settings.has(k):
			native_settings[k] = settings[k]
	tess.call("set_settings", native_settings)
	return tess


## Worker thread: both tessellation passes and the LODs. Touches no node.
func _work() -> void:
	_ok = _tess.call("run")
	if not _ok:
		return
	stats.merge(_tess.call("get_stats"), true)
	var surfaces: Array = _tess.call("get_surfaces")
	_importer = ImporterMesh.new()
	var flags := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	for s in surfaces.size():
		var arrays: Array = surfaces[s]
		if (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty():
			continue # A surface whose triangles were all degenerate.
		# The mesh's own surface material: overrides on the node keep working on the baked mesh.
		_importer.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, _source.surface_get_material(s),
			(_source as ArrayMesh).surface_get_name(s) if _source is ArrayMesh else "", flags)
	if _importer.get_surface_count() == 0:
		_ok = false
		return
	if _settings.get("lods", true):
		_importer.generate_lods(float(_settings.get("lod_normal_merge_angle", 60.0)), 0.0, [])
	if _cancelled:
		_ok = false
		return
	if _collision_tess != null:
		if not _collision_tess.call("run"):
			_ok = false
			return
		for arrays: Array in _collision_tess.call("get_surfaces"):
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for i: int in arrays[Mesh.ARRAY_INDEX]:
				_collision_faces.append(vertices[i])
		stats["collision_triangles"] = _collision_faces.size() / 3
