@tool
@icon("res://addons/surface_displacement/icons/displacement_field_3d.svg")
class_name DisplacementField3D
extends Node3D
## Real displaced ground geometry around the camera: a geometry clipmap whose vertices take their
## height from the ground's height maps, fading into the ground material's parallax occlusion
## mapping at its edge (7.7 m out with the default 3 rings of 96 quads at 4 cm).
##
## The field draws ON TOP of the original ground ("up only" relief plus [member lift]); the ground
## mesh and its collision stay. Its layers are the ground's own Surface Displacement materials
## (world-planar mapping, [code]height_center = 0[/code] so their parallax relief also sits
## above the surface). Where the ground under the field is not one of the layers, the field dives
## below it and the ground shows.
##
## Ground height and layers come from [member ground_bake] (a top-down capture of the meshes in
## [member ground_group], see [SDGroundBake]); without meshes in the group the ground is the
## plane at this node's height. Quality comes from [SurfaceDisplacement] presets or the
## properties below.

signal baked

## The ground's Surface Displacement materials (world-planar), at most 4. Their textures and
## parameters are copied into the field; call [method sync_layers] after changing them at runtime.
@export var layers: Array[ShaderMaterial] = []:
	set(value):
		layers = value
		_layers_dirty = true
## Height and layers of the ground. Empty: baked at runtime from [member ground_group], or a flat
## plane at this node's height when the group has no meshes.
@export var ground_bake: SDGroundBake:
	set(value):
		ground_bake = value
		_ground_dirty = true
@export_group("Ground")
## Group of the ground meshes (their descendants count too) that the bake captures.
@export var ground_group := &"sd_ground"
## Size of a bake texel (m). A ground too large for it is baked with coarser texels (at most
## [constant SDGroundBake.MAX_TEXELS] texels; Validate Setup reports it).
@export_range(0.01, 1.0, 0.005, "suffix:m") var bake_texel_size := 0.05
## Bake at runtime when [member ground_bake] is empty and the group has meshes: the first time the
## field is shown, so a preset without near-camera geometry (which hides the field) never bakes.
@export var bake_on_ready := true
@export_group("Quality")
## Nested rings (clipmap levels); each doubles the vertex spacing.
@export_range(2, 6) var levels := 3:
	set(value):
		value = clampi(value, 2, 6)
		if value != levels:
			levels = value
			_mesh_dirty = true
## Quads per ring side (a multiple of 4).
@export_range(16, 512, 4) var resolution := 96:
	set(value):
		value = maxi(16, value - value % 4)
		if value != resolution:
			resolution = value
			_mesh_dirty = true
## Vertex spacing of the innermost ring (m).
@export_range(0.005, 0.2, 0.0005, "suffix:m") var base_spacing := 0.04:
	set(value):
		value = maxf(value, 0.001)
		if value != base_spacing:
			base_spacing = value
			_params_dirty = true
## Height above the ground, so the ground mesh never pokes through (m).
@export_range(0.0, 0.02, 0.0005, "suffix:m") var lift := 0.002:
	set(value):
		lift = value
		_params_dirty = true
## Width of the outer band in which the geometry fades into parallax mapping, as a fraction of
## the reach.
@export_range(0.05, 0.6, 0.01) var fade_band := 0.25:
	set(value):
		fade_band = value
		_params_dirty = true
## Draw the field into shadow maps (re-runs its vertex shader per cascade; off by default).
@export var cast_shadows := false:
	set(value):
		cast_shadows = value
		if _mesh_instance != null:
			_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if value else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
@export_group("")
## The camera to follow. Empty: the viewport's current camera (the editor camera in the editor).
@export var camera: Camera3D

const MAX_LAYERS := 4
const MAX_LEVELS := 8

static var _mesh_cache := {}

var _quality := SDMaterials.Quality.POM_SELF_SHADOW
var _mesh_instance: MeshInstance3D
var _material: ShaderMaterial
var _layers_dirty := true
var _ground_dirty := true
var _mesh_dirty := true
var _params_dirty := true
var _baking := false
var _bake_pending := false
var _ground_texture: ImageTexture
var _flat_height := NAN
var _height_range := Vector2(-1.0, 1.0)
var _origin := Vector3.ZERO


func _enter_tree() -> void:
	add_to_group(&"surface_displacement_field")
	if _mesh_instance != null:
		_mesh_instance.visible = not _baking
	else:
		_material = ShaderMaterial.new()
		_material.shader = _field_shader(_quality)
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "FieldMesh"
		_mesh_instance.top_level = true
		_mesh_instance.material_override = _material
		_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mesh_instance, false, Node.INTERNAL_MODE_BACK)


func _ready() -> void:
	set_process(true)
	if not Engine.is_editor_hint() and ground_bake == null and bake_on_ready:
		# Decided after this frame: a SurfaceDisplacement node whose preset has no near-camera
		# geometry hides the field in its own _ready() or in a deferred apply, and then nothing is
		# baked until the field is shown.
		_bake_pending = true
		_start_pending_bake.call_deferred()


func _exit_tree() -> void:
	remove_from_group(&"surface_displacement_field")
	# The mesh cache is shared by all fields; release it with the last one so nothing outlives
	# the scene (Godot reports resources still referenced at exit).
	if get_tree().get_nodes_in_group(&"surface_displacement_field").is_empty():
		_mesh_cache.clear()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and _mesh_instance != null:
		_mesh_instance.visible = is_visible_in_tree() and not _baking
		_start_pending_bake()


## Starts the runtime bake that [member bake_on_ready] asked for once the field is visible.
func _start_pending_bake() -> void:
	if _bake_pending and is_inside_tree() and is_visible_in_tree() and not _baking:
		_bake_pending = false
		if ground_bake == null:
			bake_ground()


## True while a runtime bake ([member bake_on_ready]) waits for the field to be shown.
func is_bake_pending() -> bool:
	return _bake_pending


## Starts baking the ground from [member ground_group]; [signal baked] is emitted when done
## (await it). The field is hidden meanwhile. Needs a rendering device (not --headless).
func bake_ground() -> void:
	if _baking or not is_inside_tree():
		return
	_bake_pending = false
	var meshes := SDGroundBake.collect_ground(get_tree(), ground_group)
	if meshes.is_empty():
		_ground_dirty = true
		baked.emit()
		return
	_baking = true
	_mesh_instance.visible = false
	_bake_and_apply(weakref(self), meshes, layers, bake_texel_size)


## The bake's await runs in a static function: a field freed during the bake (a scene change)
## must not be resumed.
static func _bake_and_apply(field_ref: WeakRef, meshes: Array[MeshInstance3D], bake_layers: Array, texel: float) -> void:
	var result := await SDGroundBake.bake(meshes, bake_layers, texel)
	var field := field_ref.get_ref() as DisplacementField3D
	if field != null:
		field._finish_bake(result)


func _finish_bake(result: SDGroundBake) -> void:
	_baking = false
	ground_bake = result
	# Out of the tree the mesh instance is not drawn anyway; _enter_tree() shows it again.
	_mesh_instance.visible = true
	baked.emit()


## True while a runtime bake is running.
func is_baking() -> bool:
	return _baking


## Copies the layer materials' textures and parameters into the field (automatic when [member
## layers] is assigned; call it after changing a layer material's parameters).
func sync_layers() -> void:
	_layers_dirty = true


## Quality variant of the field shader (flat, POM, POM with self-shadow), as the surfaces use.
func set_quality(quality: SDMaterials.Quality) -> void:
	_quality = quality
	if _material != null:
		_material.shader = _field_shader(quality)


func get_quality() -> SDMaterials.Quality:
	return _quality


## Half the side of the outermost ring (m): how far the geometry reaches from the camera.
func get_reach() -> float:
	return resolution / 2.0 * pow(2.0, levels - 1) * base_spacing


## The grid's snapping step (m): its origin moves in multiples of this, so every ring's vertices
## stay on the same world positions.
func get_snap() -> float:
	return pow(2.0, levels) * base_spacing


## Where the relief fades out: (start, end) distance from the camera (m).
func get_fade_range() -> Vector2:
	var reach := get_reach()
	var fade_end := reach - get_snap() * 0.5 - base_spacing * pow(2.0, levels - 1)
	return Vector2(fade_end - fade_band * reach, fade_end)


## Morph range (start, end) in metres of ring [param k]; see the shader header. The last ring
## does not morph.
func get_morph_range(k: int) -> Vector2:
	if k >= levels - 1:
		return Vector2(1e9, 1e9 + 1.0)
	var spacing := base_spacing * pow(2.0, k)
	var outer := resolution / 2.0 * spacing
	var delta := get_snap() * 0.5
	var end := outer - delta - spacing
	var start := end - 0.3 * outer
	if k > 0:
		start = maxf(start, sqrt(2.0) * (outer * 0.5 + delta) + spacing)
	return Vector2(minf(start, end - 1e-3), end)


## The snapped world origin of the lattice for camera position [param p].
func snapped_origin(p: Vector3) -> Vector3:
	var snap := get_snap()
	return Vector3(floorf(p.x / snap + 0.5) * snap, 0.0, floorf(p.z / snap + 0.5) * snap)


func get_mesh_instance() -> MeshInstance3D:
	return _mesh_instance


func get_material() -> ShaderMaterial:
	return _material


func _process(_delta: float) -> void:
	if _mesh_instance == null:
		return
	if _mesh_dirty:
		_mesh_dirty = false
		_mesh_instance.mesh = build_mesh(levels, resolution)
		_params_dirty = true
	if _layers_dirty:
		_layers_dirty = false
		_apply_layers()
		_params_dirty = true
	if _ground_dirty:
		_ground_dirty = false
		_apply_ground()
		_params_dirty = true
	if Engine.is_editor_hint() and Engine.get_process_frames() % 30 == 0:
		# Parameters may have been edited on the layer materials.
		_apply_layers()
	if ground_bake == null and global_position.y != _flat_height:
		# The flat ground follows the node.
		_ground_dirty = true
	var cam := _find_camera()
	if cam == null:
		return
	var p := cam.global_position
	if _params_dirty:
		_params_dirty = false
		_apply_params()
	_origin = snapped_origin(p)
	_mesh_instance.global_transform = Transform3D(Basis.IDENTITY, _origin)
	_material.set_shader_parameter("field_origin", _origin)
	_material.set_shader_parameter("field_camera", p)
	_material.set_shader_parameter("pixel_size", camera_pixel_size(cam))


## Size of a pixel of [param cam] at its render resolution: x = radians (perspective), y = metres
## (orthogonal; x is then 0). The field's vertices use it to fade their relief with the mip level
## the fragments will march.
static func camera_pixel_size(cam: Camera3D) -> Vector2:
	var vp := cam.get_viewport()
	var size := Vector2(1920.0, 1080.0)
	if vp != null:
		size = vp.get_visible_rect().size * vp.scaling_3d_scale
	var pixels := maxf(size.x if cam.keep_aspect == Camera3D.KEEP_WIDTH else size.y, 1.0)
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return Vector2(0.0, cam.size / pixels)
	return Vector2(2.0 * tan(deg_to_rad(cam.fov) * 0.5) / pixels, 0.0)


func _find_camera() -> Camera3D:
	if camera != null and is_instance_valid(camera):
		return camera
	if Engine.is_editor_hint():
		var editor := Engine.get_singleton(&"EditorInterface")
		if editor != null:
			var vp: SubViewport = editor.get_editor_viewport_3d(0)
			return vp.get_camera_3d() if vp != null else null
		return null
	return get_viewport().get_camera_3d() if get_viewport() != null else null


func _field_shader(quality: SDMaterials.Quality) -> Shader:
	return load(SDMaterials.VARIANT_DIR + "sd_field_%s.gdshader" % SDMaterials.QUALITY_NAMES[quality])


func _apply_params() -> void:
	_material.set_shader_parameter("base_spacing", base_spacing)
	_material.set_shader_parameter("lift", lift)
	var morph: Array[Vector4] = []
	for k in MAX_LEVELS:
		var r := get_morph_range(k) if k < levels else Vector2(1e9, 1e9 + 1.0)
		morph.append(Vector4(r.x, r.y, 0.0, 0.0))
	_material.set_shader_parameter("level_morph", morph)
	_material.set_shader_parameter("amp_fade", get_fade_range())
	var max_amp := 0.0
	for layer in layers:
		if layer != null:
			max_amp = maxf(max_amp, float(_param(layer, "height_m")))
	var push := maxf(0.05, 2.0 * max_amp + 0.02)
	_material.set_shader_parameter("push_down", push)
	var reach := get_reach()
	_mesh_instance.custom_aabb = AABB(Vector3(-reach, _height_range.x - push - 0.1, -reach),
			Vector3(2.0 * reach, _height_range.y - _height_range.x + push + max_amp + 0.2, 2.0 * reach))


func _apply_ground() -> void:
	if ground_bake != null and ground_bake.data != null:
		_ground_texture = ImageTexture.create_from_image(ground_bake.data)
		_material.set_shader_parameter("ground_mode", 1)
		_material.set_shader_parameter("ground_data", _ground_texture)
		_material.set_shader_parameter("ground_rect", Vector4(ground_bake.origin.x, ground_bake.origin.y, ground_bake.texel_size, 0.0))
		_material.set_shader_parameter("ground_decode", Vector4(ground_bake.height_min, ground_bake.height_range, ground_bake.step_limit, 0.0))
		_height_range = ground_bake.get_height_range()
		_flat_height = NAN
	else:
		_ground_texture = null
		_material.set_shader_parameter("ground_mode", 0)
		_material.set_shader_parameter("ground_data", null)
		var y := global_position.y if is_inside_tree() else 0.0
		_material.set_shader_parameter("ground_rect", Vector4(0.0, 0.0, 1.0, y))
		_height_range = Vector2(y, y)
		_flat_height = y


static func _param(material: ShaderMaterial, name: String) -> Variant:
	return SDMaterials.get_param(material, name)


func _apply_layers() -> void:
	var count := mini(layers.size(), MAX_LAYERS)
	var heights: Array[Texture2D] = []
	var albedos: Array[Texture2D] = []
	var normals: Array[Texture2D] = []
	var orms: Array[Texture2D] = []
	var a: Array[Vector4] = []
	var b: Array[Vector4] = []
	var c: Array[Vector4] = []
	var d: Array[Vector4] = []
	var e: Array[Vector4] = []
	for i in MAX_LAYERS:
		var m: ShaderMaterial = layers[i] if i < count else null
		if m == null:
			heights.append(null)
			albedos.append(null)
			normals.append(null)
			orms.append(null)
			a.append(Vector4(0, 0, 1, 1))
			b.append(Vector4(0.5, 0.5, 0, 0))
			c.append(Vector4(1, 0, 1, 1))
			d.append(Vector4(1, 1, 1, 0))
			e.append(Vector4(0.5, 1, 1, 0))
			continue
		var height_tex: Texture2D = _param(m, "height_texture")
		heights.append(height_tex)
		albedos.append(_param(m, "albedo_texture"))
		normals.append(_param(m, "normal_texture"))
		orms.append(_param(m, "orm_texture"))
		var remap: Vector2 = _param(m, "height_remap")
		a.append(Vector4(_param(m, "height_m"), remap.x, remap.y, _param(m, "normal_strength")))
		var size: Vector2 = _param(m, "texture_size_m")
		var offset: Vector2 = _param(m, "planar_offset_m")
		b.append(Vector4(1.0 / size.x, 1.0 / size.y, offset.x, offset.y))
		var rot := deg_to_rad(float(_param(m, "planar_rotation_deg")))
		c.append(Vector4(cos(rot), sin(rot), _param(m, "ao_strength"), _param(m, "roughness_scale")))
		var tint: Color = _param(m, "albedo_tint")
		d.append(Vector4(tint.r, tint.g, tint.b, _param(m, "metallic_scale")))
		var texel := size.x / float(height_tex.get_width()) if height_tex != null else size.x / 1024.0
		e.append(Vector4(_param(m, "specular"), _param(m, "pom_steps_scale"), _param(m, "self_shadow_strength"), -log(texel) / log(2.0)))
	_material.set_shader_parameter("layer_count", count)
	_material.set_shader_parameter("layer_height", heights)
	_material.set_shader_parameter("layer_albedo", albedos)
	_material.set_shader_parameter("layer_normal", normals)
	_material.set_shader_parameter("layer_orm", orms)
	_material.set_shader_parameter("layer_a", a)
	_material.set_shader_parameter("layer_b", b)
	_material.set_shader_parameter("layer_c", c)
	_material.set_shader_parameter("layer_d", d)
	_material.set_shader_parameter("layer_e", e)


## The clipmap mesh: [param levels] rings of [param n] x [param n] quads (vertex positions in
## lattice units of the innermost spacing; the shader places them). Cached per (levels, n).
static func build_mesh(levels: int, n: int) -> ArrayMesh:
	var key := Vector2i(levels, n)
	if _mesh_cache.has(key):
		return _mesh_cache[key]
	var positions := PackedVector3Array()
	var lattice := PackedVector2Array()
	var info := PackedVector2Array()
	var indices := PackedInt32Array()
	var half := n / 2
	var hole := n / 4
	for k in levels:
		var step := 1 << k
		var ids := PackedInt32Array()
		ids.resize((n + 1) * (n + 1))
		ids.fill(-1)
		for j in range(-half, half + 1):
			for i in range(-half, half + 1):
				var ring := maxi(absi(i), absi(j))
				if k > 0 and ring < hole:
					continue
				var flag := 0.0
				if ring == half and k < levels - 1:
					flag = 1.0
				elif k > 0 and ring == hole:
					flag = 2.0
				ids[(j + half) * (n + 1) + i + half] = positions.size()
				positions.append(Vector3(i * step, 0.0, j * step))
				lattice.append(Vector2(i * step, j * step))
				info.append(Vector2(k, flag))
		for j in range(-half, half):
			for i in range(-half, half):
				if k > 0 and i >= -hole and i + 1 <= hole and j >= -hole and j + 1 <= hole:
					continue
				var a := ids[(j + half) * (n + 1) + i + half]
				var b := ids[(j + half) * (n + 1) + i + 1 + half]
				var c := ids[(j + 1 + half) * (n + 1) + i + 1 + half]
				var d := ids[(j + 1 + half) * (n + 1) + i + half]
				# Clockwise seen from above: front faces up in Godot.
				indices.append_array(PackedInt32Array([a, b, c, a, c, d]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_TEX_UV] = lattice
	arrays[Mesh.ARRAY_TEX_UV2] = info
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_cache[key] = mesh
	return mesh
