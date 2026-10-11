@tool
@icon("res://addons/gads/icons/gads_displacement_field_3d.svg")
class_name GADSDisplacementField3D
extends Node3D
## Real displaced ground geometry around the camera: a geometry clipmap whose vertices take their
## height from the ground's height maps, fading into the ground material's parallax occlusion
## mapping at its edge (7.7 m out with the default 3 rings of 96 quads at 4 cm).
##
## The field draws ON TOP of the original ground ("up only" relief plus [member lift]); the ground
## mesh and its collision stay. Its layers are the ground's own GADS materials
## (world-planar mapping, [code]height_center = 0[/code] so their parallax relief also sits
## above the surface). Where the ground under the field is not one of the layers, the field dives
## below it and the ground shows.
##
## Ground height and layers come from [member ground_bake] (a top-down capture of the meshes in
## [member ground_group], see [GADSGroundBake]); without meshes in the group the ground is the
## plane at this node's height. Quality comes from [GADSManager] presets or the
## properties below.

signal baked

## The ground's GADS materials (world-planar), at most 4. Their textures and
## parameters are copied into the field; call [method sync_layers] after changing them at runtime.
@export var layers: Array[ShaderMaterial] = []:
	set(value):
		layers = value
		_layers_dirty = true
## Height and layers of the ground. Empty: baked at runtime from [member ground_group], or a flat
## plane at this node's height when the group has no meshes.
@export var ground_bake: GADSGroundBake:
	set(value):
		ground_bake = value
		_ground_dirty = true
		if value != null and _no_ground:
			_no_ground = false
			if _mesh_instance != null:
				_mesh_instance.visible = is_visible_in_tree() and not _baking
@export_group("Ground")
## Group of the ground meshes (their descendants count too) that the bake captures.
@export var ground_group := &"gads_ground"
## Size of a bake texel (m).
@export_range(0.01, 1.0, 0.005, "suffix:m") var bake_texel_size := 0.05
## Bake at runtime when [member ground_bake] is empty and the group has meshes.
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
## The height range of the transition between two layers' reliefs where they meet (normalised
## heights; the layered material's default layer blend width).
const BLEND_WIDTH := 0.1
## The field shader's per-layer surface-effect parameters (see _apply_layers).
const EFFECT_PARAMS := ["layer_fx_cover_color", "layer_fx_cover", "layer_fx_water", "layer_fx_cavity", "layer_fx_edge", "layer_fx_radius"]
const MAX_LEVELS := 8

static var _mesh_cache := {}

var _quality := GADSMaterials.Quality.POM_SELF_SHADOW
var _mesh_instance: MeshInstance3D
var _material: ShaderMaterial
var _layers_dirty := true
var _ground_dirty := true
var _mesh_dirty := true
## Per-channel layer-array cache (see _layer_array): {channel: {"src": Array[Texture2D], "tex": ...}}.
## Rebuilding a Texture2DArray is costly (decompress + mipmaps) and yields a new object every time,
## so re-applying unchanged layers would needlessly re-upload them and bump the parameters version.
var _layer_arrays := {}
var _params_dirty := true
## Per-texel control map bound by GADSTerrain3D (see [method set_control_map]); null = the field
## keeps the ground bake's layer codes.
var _control_map: Texture2D
var _control_rect := Vector4.ZERO
var _control_dirty := false
var _baking := false
var _no_ground := false # a runtime bake of existing ground meshes failed
var _ground_texture: ImageTexture
var _height_images := {} # layer height texture -> Image (FORMAT_RF, mip 0), for get_surface_height()
var _flat_height := NAN
var _height_range := Vector2(-1.0, 1.0)
var _origin := Vector3.ZERO
var _params_version := 0


func _enter_tree() -> void:
	add_to_group(&"gads_field")
	if _mesh_instance != null:
		_mesh_instance.visible = not _baking and not _no_ground
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
		bake_ground()


func _exit_tree() -> void:
	remove_from_group(&"gads_field")
	# The mesh cache is shared by all fields; release it with the last one so nothing outlives
	# the scene (Godot reports resources still referenced at exit).
	if get_tree().get_nodes_in_group(&"gads_field").is_empty():
		_mesh_cache.clear()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and _mesh_instance != null:
		_mesh_instance.visible = is_visible_in_tree() and not _baking and not _no_ground


## Starts baking the ground from [member ground_group]; [signal baked] is emitted when done
## (await it). The field is hidden meanwhile. Needs a rendering device (not --headless).
func bake_ground() -> void:
	if _baking or not is_inside_tree():
		return
	var meshes := GADSGroundBake.collect_ground(get_tree(), ground_group)
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
	var result := await GADSGroundBake.bake(meshes, bake_layers, texel)
	var field := field_ref.get_ref() as GADSDisplacementField3D
	if field != null:
		field._finish_bake(result)


func _finish_bake(result: GADSGroundBake) -> void:
	_baking = false
	ground_bake = result
	# Without the ground it would draw a flat sheet at the node's height across the real ground:
	# it stays off (the ground keeps its parallax) until a bake is assigned.
	_no_ground = result == null
	# Out of the tree the mesh instance is not drawn anyway; _enter_tree() shows it again.
	_mesh_instance.visible = not _no_ground and is_visible_in_tree()
	baked.emit()


## True while a runtime bake is running.
func is_baking() -> bool:
	return _baking


## Copies the layer materials' textures and parameters into the field (automatic when [member
## layers] is assigned; call it after changing a layer material's parameters).
func sync_layers() -> void:
	_layers_dirty = true


## Binds a per-texel control map so the field selects and blends its layers per fragment, base-first,
## exactly as the layered chunk material does, so the near-camera relief shades like the ground right
## across a layer boundary (no visible seam). [param map]: an RGB weight texture, R/G/B = the three
## extra layers' (field layers 1, 2, 3) masks, sampled by world XZ. [param rect]: (origin.x,
## origin.z, 1/size.x, 1/size.z) in world metres (origin = the map's min corner). A null map (or
## rect.z <= 0) clears it and the field falls back to its ground bake's layer codes. GADSTerrain3D
## binds the same texture and rect here and on its chunks' material.
func set_control_map(map: Texture2D, rect: Vector4) -> void:
	var new_rect := rect if map != null else Vector4.ZERO
	if map == _control_map and new_rect == _control_rect:
		return
	_control_map = map
	_control_rect = new_rect
	_control_dirty = true


## Quality variant of the field shader (flat, POM, POM with self-shadow), as the surfaces use.
func set_quality(quality: GADSMaterials.Quality) -> void:
	_quality = quality
	if _material != null:
		_material.shader = _field_shader(quality)


func get_quality() -> GADSMaterials.Quality:
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


## The height (world y, m) of the relief this field draws at [param world_position]'s x and z,
## as close to the camera (no distance fade): the ground, plus its layers' relief (the height
## maps' full resolution, bilinear like the GPU), minus the runtime deformation; the ground alone
## where the field does not displace. NAN outside the ground data. For gameplay on the relief:
## feet, decals, projectiles, picking.
func get_surface_height(world_position: Vector3) -> float:
	var xz := Vector2(world_position.x, world_position.z)
	if ground_bake == null or not ground_bake.get_rect().has_point(xz):
		return NAN
	var s := ground_bake.sample(xz)
	var ground: float = s["height"]
	var w: Color = s["weights"]
	var count := mini(layers.size(), MAX_LAYERS)
	var sum := 0.0
	for i in MAX_LAYERS:
		if i >= count:
			w[i] = 0.0
		sum += w[i]
	var displaceable := smoothstep(0.35, 0.65, sum)
	if displaceable <= 0.0:
		return ground
	w = w / sum if sum > 1e-4 else Color(1, 0, 0, 0)
	# Blended by height, as the shader blends the layers (gads_field_layers).
	var relief := 0.0
	var h_acc := 0.0
	var acc := 0.0
	for i in count:
		if w[i] <= 0.001 or layers[i] == null:
			continue
		var hl := _layer_h(layers[i], xz)
		acc += w[i]
		var t := height_blend(h_acc, hl, w[i] / acc, BLEND_WIDTH)
		relief = lerpf(relief, float(_param(layers[i], "height_m")) * hl, t)
		h_acc = lerpf(h_acc, hl, t)
	relief *= acc
	var deformation := GADSDeformationField.find_active(get_tree()) if is_inside_tree() else null
	if deformation != null:
		relief -= deformation.get_depth(world_position)
	# Where the field dives (not displaceable) the ground's own surface shows.
	return lerpf(ground, ground + relief, displaceable)


## The surface normal of [method get_surface_height]'s relief at [param world_position] (central
## differences over [param step] metres; default a quarter of the finest layer texel, at least
## 1 mm). Vector3.ZERO outside the ground data.
func get_surface_normal(world_position: Vector3, step := -1.0) -> Vector3:
	if step <= 0.0:
		step = maxf(_finest_texel() * 0.25, 0.001)
	var hx0 := get_surface_height(world_position - Vector3(step, 0, 0))
	var hx1 := get_surface_height(world_position + Vector3(step, 0, 0))
	var hz0 := get_surface_height(world_position - Vector3(0, 0, step))
	var hz1 := get_surface_height(world_position + Vector3(0, 0, step))
	if is_nan(hx0) or is_nan(hx1) or is_nan(hz0) or is_nan(hz1):
		return Vector3.ZERO
	return Vector3(hx0 - hx1, 2.0 * step, hz0 - hz1).normalized()


## Where the segment [param from] - [param to] first meets the relief of
## [method get_surface_height]: {"position": Vector3, "normal": Vector3}, or {} when it does not
## (or leaves the ground data first). Marches in steps of half the finest layer texel (at most
## 2048 of them) and refines the crossing by bisection.
func raycast_surface(from: Vector3, to: Vector3) -> Dictionary:
	var length := from.distance_to(to)
	if length <= 0.0:
		return {}
	var steps := clampi(ceili(length / maxf(_finest_texel() * 0.5, 1e-4)), 1, 2048)
	var above := func(p: Vector3) -> float:
		var hgt := get_surface_height(p)
		return p.y - hgt if not is_nan(hgt) else NAN
	var t0 := 0.0
	var g0: float = above.call(from)
	for k in range(1, steps + 1):
		var t1 := float(k) / steps
		var g1: float = above.call(from.lerp(to, t1))
		if is_nan(g0) or is_nan(g1):
			t0 = t1
			g0 = g1
			continue
		if g0 > 0.0 and g1 <= 0.0:
			var lo := t0
			var hi := t1
			for i in 24:
				var mid := (lo + hi) * 0.5
				if float(above.call(from.lerp(to, mid))) > 0.0:
					lo = mid
				else:
					hi = mid
			var p := from.lerp(to, hi)
			return {"position": p, "normal": get_surface_normal(p)}
		t0 = t1
		g0 = g1
	return {}


## How far below the ground the field hides where it does not displace (m).
func _push_down() -> float:
	return maxf(0.05, 2.0 * _max_amp() + 0.02)


## The deepest layer relief (m).
func _max_amp() -> float:
	var max_amp := 0.0
	for layer in layers:
		if layer != null:
			max_amp = maxf(max_amp, float(_param(layer, "height_m")))
	return max_amp


func _finest_texel() -> float:
	var finest := INF
	for m: ShaderMaterial in layers:
		if m == null:
			continue
		var tex := m.get_shader_parameter("height_texture") as Texture2D
		var size: Vector2 = _param(m, "texture_size_m")
		if tex != null:
			finest = minf(finest, size.x / tex.get_width())
	return finest if finest < INF else 0.01


## A layer material's relief (m) at world xz: height_m x its remapped height map there (mip 0,
## bilinear, repeating; world-planar mapping with its size, offset and rotation).
## The weight of the relief [param above] over [param below] (normalised heights) for its share
## [param m] of the weights: the higher relief wins in between, over a transition [param width]
## high (the shaders' gads_height_blend).
static func height_blend(below: float, above: float, m: float, width: float) -> float:
	if m <= 0.0:
		return 0.0
	if m >= 1.0:
		return 1.0
	return smoothstep(-width, width, above - below + (2.0 * m - 1.0) * (1.0 + width))


## A layer's normalised height (0..1 after its remap) at world [param xz], full resolution.
func _layer_h(m: ShaderMaterial, xz: Vector2) -> float:
	var depth := float(_param(m, "height_m"))
	return _layer_relief(m, xz) / depth if absf(depth) > 1e-9 else 0.0


func _layer_relief(m: ShaderMaterial, xz: Vector2) -> float:
	var tex := m.get_shader_parameter("height_texture") as Texture2D
	if tex == null:
		return 0.0
	var img: Image = _height_images.get(tex)
	if img == null:
		img = tex.get_image()
		if img == null:
			return 0.0
		img = img.duplicate()
		if img.is_compressed():
			img.decompress()
		img.clear_mipmaps()
		img.convert(Image.FORMAT_RF)
		_height_images[tex] = img
	var size: Vector2 = _param(m, "texture_size_m")
	var offset: Vector2 = _param(m, "planar_offset_m")
	var rot := deg_to_rad(float(_param(m, "planar_rotation_deg")))
	var q := xz - offset
	var uv := Vector2(cos(rot) * q.x - sin(rot) * q.y, sin(rot) * q.x + cos(rot) * q.y) / size
	var remap: Vector2 = _param(m, "height_remap")
	var h := GADSDisplacementField3D.sample_repeat(img, uv)
	var span := remap.y - remap.x
	span = span if absf(span) >= 1e-5 else 1e-5
	return float(_param(m, "height_m")) * clampf((h - remap.x) / span, 0.0, 1.0)


## Bilinear sample with repeat wrap of [param img]'s red channel at [param uv] (texel centres at
## (i + 0.5) / size), as the GPU samples mip 0.
static func sample_repeat(img: Image, uv: Vector2) -> float:
	var w := img.get_width()
	var hh := img.get_height()
	var x := uv.x * w - 0.5
	var y := uv.y * hh - 0.5
	var x0 := floori(x)
	var y0 := floori(y)
	var fx := x - x0
	var fy := y - y0
	var a := img.get_pixel(posmod(x0, w), posmod(y0, hh)).r
	var b := img.get_pixel(posmod(x0 + 1, w), posmod(y0, hh)).r
	var c := img.get_pixel(posmod(x0, w), posmod(y0 + 1, hh)).r
	var d := img.get_pixel(posmod(x0 + 1, w), posmod(y0 + 1, hh)).r
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)


func get_mesh_instance() -> MeshInstance3D:
	return _mesh_instance


func get_material() -> ShaderMaterial:
	return _material


## Grows whenever the field changes a ground, layer or grid parameter of its material (not the
## camera and origin it updates every frame), so [GADSPebbleScatter3D] copies them only then.
func get_parameters_version() -> int:
	return _params_version


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
	if _control_dirty:
		_control_dirty = false
		_set_param("control_map", _control_map)
		_set_param("control_rect", _control_rect)
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


func _field_shader(quality: GADSMaterials.Quality) -> Shader:
	return load(GADSMaterials.VARIANT_DIR + "gads_field_%s.gdshader" % GADSMaterials.QUALITY_NAMES[quality])


## Sets a material parameter only when its value changes: setting a texture parameter, even to
## the texture it already has, makes the renderer rebuild the material's uniform set.
func _set_param(param: String, value: Variant) -> void:
	if _material.get_shader_parameter(param) != value:
		_material.set_shader_parameter(param, value)
		_params_version += 1


func _apply_params() -> void:
	_set_param("base_spacing", base_spacing)
	_set_param("lift", lift)
	var morph: Array[Vector4] = []
	for k in MAX_LEVELS:
		var r := get_morph_range(k) if k < levels else Vector2(1e9, 1e9 + 1.0)
		morph.append(Vector4(r.x, r.y, 0.0, 0.0))
	_set_param("level_morph", morph)
	_set_param("amp_fade", get_fade_range())
	var push := _push_down()
	_set_param("push_down", push)
	var reach := get_reach()
	_mesh_instance.custom_aabb = AABB(Vector3(-reach, _height_range.x - push - 0.1, -reach),
			Vector3(2.0 * reach, _height_range.y - _height_range.x + push + _max_amp() + 0.2, 2.0 * reach))


func _apply_ground() -> void:
	if ground_bake != null and ground_bake.data != null:
		_ground_texture = ImageTexture.create_from_image(ground_bake.data)
		_set_param("ground_mode", 1)
		_set_param("ground_data", _ground_texture)
		_set_param("ground_rect", Vector4(ground_bake.origin.x, ground_bake.origin.y, ground_bake.texel_size, 0.0))
		_set_param("ground_decode", Vector4(ground_bake.height_min, ground_bake.height_range, ground_bake.step_limit, 0.0))
		_height_range = ground_bake.get_height_range()
		_flat_height = NAN
	else:
		_ground_texture = null
		_set_param("ground_mode", 0)
		_set_param("ground_data", null)
		var y := global_position.y if is_inside_tree() else 0.0
		_set_param("ground_rect", Vector4(0.0, 0.0, 1.0, y))
		_height_range = Vector2(y, y)
		_flat_height = y


static func _param(material: ShaderMaterial, name: String) -> Variant:
	return GADSMaterials.get_param(material, name)


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
	var anim: Array[Vector4] = []
	var effects: Array = []
	for k in EFFECT_PARAMS.size():
		effects.append([] as Array[Vector4])
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
			anim.append(Vector4.ZERO)
			for fx in effects:
				fx.append(Vector4.ZERO)
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
		# The materials' colours are source_color uniforms, which Godot hands to the shader in
		# linear space; the field's arrays are plain vec4s, so they are converted here.
		var tint: Color = (_param(m, "albedo_tint") as Color).srgb_to_linear()
		d.append(Vector4(tint.r, tint.g, tint.b, _param(m, "metallic_scale")))
		var texel := size.x / float(height_tex.get_width()) if height_tex != null else size.x / 1024.0
		e.append(Vector4(_param(m, "specular"), _param(m, "pom_steps_scale"), _param(m, "self_shadow_strength"), -log(texel) / log(2.0)))
		var flow: Vector2 = _param(m, "flow_speed")
		anim.append(Vector4(flow.x, flow.y, _param(m, "pulse_amount"), _param(m, "pulse_rate")))
		var cover_color: Color = (_param(m, "cover_color") as Color).srgb_to_linear()
		var slope: Vector2 = _param(m, "cover_slope")
		var cavity_color: Color = (_param(m, "cavity_color") as Color).srgb_to_linear()
		var edge_color: Color = (_param(m, "edge_color") as Color).srgb_to_linear()
		effects[0].append(Vector4(cover_color.r, cover_color.g, cover_color.b, _param(m, "cover_roughness")))
		effects[1].append(Vector4(_param(m, "cover_amount"), slope.x, slope.y, _param(m, "cover_height_bias")))
		effects[2].append(Vector4(_param(m, "wetness"), _param(m, "puddle_level"), _param(m, "weather_response"), _param(m, "cover_sharpness")))
		effects[3].append(Vector4(cavity_color.r, cavity_color.g, cavity_color.b, _param(m, "cavity_amount")))
		effects[4].append(Vector4(edge_color.r, edge_color.g, edge_color.b, _param(m, "edge_amount")))
		effects[5].append(Vector4(_param(m, "cavity_radius"), 0, 0, 0))
	_set_param("layer_count", count)
	# One array texture per channel (see GADSMaterials.build_layer_array): the shader samples all
	# layers through a single texture unit, staying within the Compatibility 16-unit limit. Height
	# keeps float precision (FORMAT_RF); the others are colour (FORMAT_RGBA8). Each slice keeps the
	# source's imported mip chain, so the array's smaller levels match the per-material textures the
	# field blends into (a plain regenerate flattened the normal mips and brightened the field).
	_set_param("layer_height", _layer_array("height", heights, Image.FORMAT_RF, Color(0, 0, 0, 0)))
	_set_param("layer_albedo", _layer_array("albedo", albedos, Image.FORMAT_RGBA8, Color(1, 1, 1, 1)))
	_set_param("layer_normal", _layer_array("normal", normals, Image.FORMAT_RGBA8, Color(0.5, 0.5, 1, 1)))
	_set_param("layer_orm", _layer_array("orm", orms, Image.FORMAT_RGBA8, Color(1, 1, 1, 1)))
	_set_param("layer_a", a)
	_set_param("layer_b", b)
	_set_param("layer_c", c)
	_set_param("layer_d", d)
	_set_param("layer_e", e)
	_set_param("layer_anim", anim)
	for k in EFFECT_PARAMS.size():
		_set_param(EFFECT_PARAMS[k], effects[k])


## The layer array for [param channel], reusing the cached one while the source textures are
## unchanged (same references, compared by value) so re-applying identical layers neither rebuilds
## the array nor bumps the parameters version. A changed texture reference misses and rebuilds.
func _layer_array(channel: String, textures: Array[Texture2D], format: Image.Format, fill: Color) -> Texture2DArray:
	var cached: Dictionary = _layer_arrays.get(channel, {})
	if cached.get("src") == textures:
		return cached["tex"]
	var tex := GADSMaterials.build_layer_array(textures, format, fill)
	_layer_arrays[channel] = {"src": textures.duplicate(), "tex": tex}
	return tex


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
				# The shader places every vertex from its lattice coordinates (UV); the positions
				# stay at the origin, so the mesh is nothing but degenerate triangles to anything
				# that reads it on the CPU (a navigation mesh bake would otherwise take the flat
				# lattice for ground). The node sets a custom AABB for culling.
				positions.append(Vector3.ZERO)
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
