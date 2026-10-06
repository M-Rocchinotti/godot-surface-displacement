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

## Optional: the height maps' images by texture, filled and reused across bakes that share it (the
## runtime tessellation of a GADSMeshInstance3D re-reads the same maps every time).
var image_cache: Dictionary
## Sculpt offsets (FORMAT_RF, metres along the displacement direction) in the source mesh's own
## first UVs, added on every surface (GADSMeshInstance3D.sculpt_map). Set before start().
var sculpt_image: Image

var _source: Mesh
var _materials: Array[Material] = []
var _transform := Transform3D.IDENTITY
var _settings := {}
var _tess: RefCounted
var _collision_tess: RefCounted
var _task := -1
var _importers: Array[ImporterMesh] = [] # one per cluster (one when not clustered)
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
	var mapping: int = GADSMaterials.parse(sm.shader)["mapping"]
	var height := sm.get_shader_parameter("height_texture") as Texture2D
	var height_m: float = GADSMaterials.get_param(sm, "height_m")
	var vector := sm.get_shader_parameter("vector_displacement_texture") as Texture2D if mapping == GADSMaterials.Mapping.UV else null
	var vector_m: float = GADSMaterials.get_param(sm, "vector_displacement_m") if vector != null else 0.0
	var has_height := height != null and height_m > 0.0
	if not has_height and vector_m <= 0.0:
		return {}
	var out := {
		# Without a height map (a vector map alone) the height is flat: "texture" null, height 0.
		"texture": height if has_height else null,
		"mapping": mapping,
		"height_m": height_m if has_height else 0.0,
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
		"layers": _layers_of(sm),
	}
	if vector_m > 0.0:
		out["vector_texture"] = vector
		out["vector_m"] = vector_m
		out["vector_space"] = GADSMaterials.get_param(sm, "vector_displacement_space")
		out["vector_signed"] = GADSMaterials.get_param(sm, "vector_displacement_signed")
	return out


## The layers of a layered GADS material, as the tessellator takes them (with "texture").
static func _layers_of(sm: ShaderMaterial) -> Array:
	var out := []
	if not GADSMaterials.parse(sm.shader).get("layered", false):
		return out
	for k in [1, 2]:
		var prefix := "layer%d_" % k
		var tex := sm.get_shader_parameter(prefix + "height_texture") as Texture2D
		var amount: float = GADSMaterials.get_param(sm, prefix + "amount")
		# The tessellator takes the layers in order: an unused layer 1 still holds layer 2's place.
		out.append({
			"texture": tex if amount > 0.0 else null,
			"height_m": GADSMaterials.get_param(sm, prefix + "height_m"),
			"scale": GADSMaterials.get_param(sm, prefix + "scale"),
			"mask_channel": GADSMaterials.get_param(sm, prefix + "mask_channel"),
			"amount": amount if tex != null else 0.0,
			"slope": GADSMaterials.get_param(sm, prefix + "slope"),
			"blend_width": GADSMaterials.get_param(sm, prefix + "blend_width"),
		})
	return out


## Why [param mesh] cannot be baked, or "" when it can.
static func check_mesh(mesh: Mesh) -> String:
	if mesh == null:
		return "no source mesh"
	if mesh.get_surface_count() == 0:
		return "the source mesh has no surfaces"
	for s in mesh.get_surface_count():
		if surface_primitive(mesh, s) != Mesh.PRIMITIVE_TRIANGLES:
			return "surface %d is not made of triangles" % s
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
			if d.has("vector_texture"):
				d["vector_texture"] = _resource_id(d["vector_texture"])
			var layer_ids := []
			for layer: Dictionary in d["layers"]:
				var l := layer.duplicate()
				l["texture"] = _resource_id(l["texture"])
				layer_ids.append(l)
			d["layers"] = layer_ids
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
	if not path.is_empty() and not path.contains("::") and res.has_meta(GADSVertexPaint.HASH_META):
		return "%s#%s" % [path, res.get_meta(GADSVertexPaint.HASH_META)]
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
			if mesh is ArrayMesh and (mesh as ArrayMesh).get_blend_shape_count() > 0:
				ctx.update(var_to_bytes(mesh.surface_get_blend_shape_arrays(s)))
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
## pass's tolerance relative to the render pass's), "lods" (bool), "lod_normal_merge_angle" and
## "cluster_triangles" (split the result into spatial clusters of at most this many triangles,
## each with its own LODs: [member mesh] is the first, its "gads_clusters" metadata the others).
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
	var meshes: Array[ArrayMesh] = []
	for im in _importers:
		var m := im.get_mesh()
		m.resource_name = (_source.resource_name if not _source.resource_name.is_empty() else "mesh") + " (GADS baked)"
		meshes.append(m)
	mesh = meshes[0]
	if meshes.size() > 1:
		# A clustered bake: the first cluster is the mesh, the others ride along in its metadata
		# (saved with it), drawn by GADSMeshInstance3D's internal children.
		for i in meshes.size():
			meshes[i].resource_name += " cluster %d" % (i + 1)
		mesh.set_meta(&"gads_clusters", meshes.slice(1))
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
	_importers.clear()
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
			var vector_tex: Texture2D = d.get("vector_texture")
			d.erase("vector_texture")
			if vector_tex != null:
				var key := [vector_tex, "vector"]
				if not maps.has(key):
					var img := _image_of(vector_tex)
					if img == null or img.is_empty():
						error = "cannot read the vector displacement map %s" % vector_tex.resource_path
						return null
					maps[key] = tess.call("add_vector_map", img)
				d["vector_map"] = Array(maps[key])
				if d["texture"] == null:
					# A vector map alone: a flat height map of its size (texel sizes follow it).
					var size := Vector2i(vector_tex.get_width(), vector_tex.get_height())
					if not maps.has(size):
						maps[size] = tess.call("add_height_map", Image.create_empty(size.x, size.y, false, Image.FORMAT_RF))
					d["height_map"] = maps[size]
			for key: String in ["texture", "detail_texture"]:
				var tex: Texture2D = d[key]
				d.erase(key)
				if tex == null:
					continue
				if not maps.has(tex):
					var img := _image_of(tex)
					if img == null or img.is_empty():
						error = "cannot read the height map %s" % tex.resource_path
						return null
					maps[tex] = tess.call("add_height_map", img)
				d["height_map" if key == "texture" else "detail_height_map"] = maps[tex]
			var layers := []
			for layer: Dictionary in d["layers"]:
				var l := layer.duplicate()
				var tex: Texture2D = l["texture"]
				l.erase("texture")
				if tex != null:
					if not maps.has(tex):
						var img := _image_of(tex)
						if img == null or img.is_empty():
							error = "cannot read the layer height map %s" % tex.resource_path
							return null
						maps[tex] = tess.call("add_height_map", img)
					l["height_map"] = maps[tex]
				layers.append(l)
			d["layers"] = layers
		tess.call("add_surface", _source.surface_get_arrays(s), d)
		var shaped := _source as ArrayMesh
		if shaped != null and shaped.get_blend_shape_count() > 0:
			# Shape arrays hold absolute positions in either mode (the mode only changes how weights
			# combine).
			tess.call("set_blend_shapes", s, shaped.surface_get_blend_shape_arrays(s), false)
	tess.call("set_transform", _transform)
	if sculpt_image != null:
		tess.call("set_offset_map", sculpt_image)
	var native_settings := {}
	for k: String in ["max_error", "min_edge_texels", "max_triangles", "max_level", "lock_borders", "weld_distance",
			"direction_mode", "direction", "geometry_normals", "hard_angle_deg", "filter_heights", "threads",
			"view_dependent", "view_position", "pixel_error", "focal_px", "min_edge_pixels"]:
		if settings.has(k):
			native_settings[k] = settings[k]
	tess.call("set_settings", native_settings)
	return tess


func _image_of(tex: Texture2D) -> Image:
	if image_cache != null and image_cache.has(tex):
		return image_cache[tex]
	var img := tex.get_image()
	if image_cache != null and img != null:
		image_cache[tex] = img
	return img


## Worker thread: both tessellation passes and the LODs. Touches no node.
func _work() -> void:
	_ok = _tess.call("run")
	if not _ok:
		return
	stats.merge(_tess.call("get_stats"), true)
	var flags := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) | (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	var target := int(_settings.get("cluster_triangles", 0))
	var groups: Array
	if target > 0 and int(stats.get("triangles", 0)) > target:
		groups = _tess.call("get_cluster_surfaces", target)
		stats["clusters"] = groups.size()
	else:
		groups = [_tess.call("get_surfaces")]
	_importers.clear()
	var shaped := _source as ArrayMesh
	var shape_count := shaped.get_blend_shape_count() if shaped != null else 0
	for surfaces: Array in groups:
		var im := ImporterMesh.new()
		# Blend shapes come back as absolute positions, after each surface's arrays.
		for k in shape_count:
			im.add_blend_shape(shaped.get_blend_shape_name(k))
		if shape_count > 0:
			im.set_blend_shape_mode(shaped.blend_shape_mode)
		var anchor := _anchor_of(surfaces)
		for s in surfaces.size():
			var arrays: Array = (surfaces[s] as Array).duplicate()
			var shapes: Array = arrays.pop_back() if arrays.size() > Mesh.ARRAY_MAX else []
			if (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).is_empty():
				if groups.size() == 1:
					continue # A surface whose triangles were all degenerate.
				# A cluster without this surface: a degenerate triangle keeps the surface indices
				# (and so the node's surface material overrides) the same in every cluster.
				arrays = _placeholder_surface(anchor)
				shapes = []
			if shapes.size() < shape_count:
				# A surface without shapes of its own (a placeholder): it keeps its base in every shape.
				shapes = []
				for k in shape_count:
					var a := []
					a.resize(Mesh.ARRAY_MAX)
					a[Mesh.ARRAY_VERTEX] = arrays[Mesh.ARRAY_VERTEX]
					a[Mesh.ARRAY_NORMAL] = arrays[Mesh.ARRAY_NORMAL]
					a[Mesh.ARRAY_TANGENT] = arrays[Mesh.ARRAY_TANGENT]
					shapes.append(a)
			# The mesh's own surface material: overrides on the node keep working on the baked mesh.
			# Skinned surfaces keep their bones (4 or 8 influences a vertex, as the source).
			var surface_flags := flags
			var weights: Variant = arrays[Mesh.ARRAY_WEIGHTS]
			if weights is PackedFloat32Array and (weights as PackedFloat32Array).size() == 8 * (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size():
				surface_flags |= Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS
			im.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays, shapes, {}, _source.surface_get_material(s),
				(_source as ArrayMesh).surface_get_name(s) if _source is ArrayMesh else "", surface_flags)
		if im.get_surface_count() == 0:
			_ok = false
			return
		if _settings.get("lods", true):
			im.generate_lods(float(_settings.get("lod_normal_merge_angle", 60.0)), 0.0, [])
		if _cancelled:
			_ok = false
			return
		_importers.append(im)
	if _collision_tess != null:
		if not _collision_tess.call("run"):
			_ok = false
			return
		for arrays: Array in _collision_tess.call("get_surfaces"):
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			for i: int in arrays[Mesh.ARRAY_INDEX]:
				_collision_faces.append(vertices[i])
		stats["collision_triangles"] = _collision_faces.size() / 3


## A vertex of a cluster's surfaces (where its placeholder surfaces sit, inside its bounds).
static func _anchor_of(surfaces: Array) -> Vector3:
	for arrays: Array in surfaces:
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if not v.is_empty():
			return v[0]
	return Vector3.ZERO


## One degenerate triangle at [param at] with the attributes a baked surface has.
static func _placeholder_surface(at: Vector3) -> Array:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([at, at, at])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP])
	arrays[Mesh.ARRAY_TANGENT] = PackedFloat32Array([1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1])
	var custom := PackedFloat32Array()
	custom.resize(12)
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	arrays[Mesh.ARRAY_CUSTOM1] = custom
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2])
	return arrays
