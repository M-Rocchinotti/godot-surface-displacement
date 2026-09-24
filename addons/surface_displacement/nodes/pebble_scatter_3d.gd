@tool
@icon("res://addons/surface_displacement/icons/pebble_scatter_3d.svg")
class_name PebbleScatter3D
extends Node3D
## Loose pebbles around the camera on the ground of its parent [DisplacementField3D]: real little
## stones with silhouettes, which break the "painted on" look of gravel at grazing angles.
##
## One GPUParticles3D whose particles are pebble slots in a window of cells that follows the
## camera (the pattern of Terrain3D's particle example, MIT); a particle shader places each pebble
## from a hash of its cell's world coordinates, on the ground plus the layer's relief, with density
## from the layer weights and a preference for the height map's valleys. Pebble meshes are
## generated here (noise-displaced icospheres, 80 triangles); pebbles cast no shadows.

## Fraction of the slots used (0-1); [SurfaceDisplacement] presets set it.
@export_range(0.0, 1.0, 0.05) var density := 1.0:
	set(value):
		density = value
		_dirty = true
## Pebbles fade out (shrink) towards this distance from the camera (m).
@export_range(2.0, 30.0, 0.5, "suffix:m") var radius := 8.0:
	set(value):
		radius = value
		_dirty = true
## Pebble slots per cell (the maximum density: slots / cell_size^2 per square metre).
@export_range(1, 128) var per_cell := 24:
	set(value):
		per_cell = value
		_dirty = true
@export_range(0.25, 4.0, 0.25, "suffix:m") var cell_size := 1.0:
	set(value):
		cell_size = value
		_dirty = true
## Smallest and largest pebble (longest axis, m).
@export var size_range := Vector2(0.012, 0.035):
	set(value):
		size_range = value
		_dirty = true
## How strongly pebbles prefer the height map's valleys (0 = anywhere).
@export_range(0.0, 8.0, 0.25) var valley_bias := 1.0:
	set(value):
		valley_bias = value
		_dirty = true
## Density multiplier per field layer (x = layer 0 ...); default: pebbles on layer 0 only.
@export var layer_density := Vector4(1.0, 0.0, 0.0, 0.0):
	set(value):
		layer_density = value
		_dirty = true

const PROCESS_SHADER := preload("res://addons/surface_displacement/shaders/sd_pebble_process.gdshader")
const PEBBLE_SHADER := preload("res://addons/surface_displacement/shaders/sd_pebble.gdshader")
const COPIED_FROM_FIELD := ["ground_mode", "ground_data", "ground_rect", "ground_decode", "layer_count",
		"layer_height", "layer_a", "layer_b", "layer_c", "layer_e", "lift", "base_spacing"]
const COPIED_TO_PEBBLES := ["layer_albedo", "layer_orm", "layer_b", "layer_c", "layer_d"]

var _particles: GPUParticles3D
var _process_material: ShaderMaterial
var _pebble_material: ShaderMaterial
var _dirty := true


func _enter_tree() -> void:
	add_to_group(&"surface_displacement_scatter")
	if _particles == null:
		_process_material = ShaderMaterial.new()
		_process_material.shader = PROCESS_SHADER
		_pebble_material = ShaderMaterial.new()
		_pebble_material.shader = PEBBLE_SHADER
		_particles = GPUParticles3D.new()
		_particles.name = "Pebbles"
		_particles.top_level = true
		_particles.local_coords = false
		_particles.explosiveness = 1.0
		_particles.lifetime = 3600.0
		_particles.interpolate = false
		_particles.fract_delta = false
		# Process every frame (the default, 30 steps per second, would leave the new cells of a
		# moved window empty or showing their old pebbles for a frame or more).
		_particles.fixed_fps = 0
		_particles.process_material = _process_material
		_particles.draw_pass_1 = make_pebble_mesh(1)
		_particles.material_override = _pebble_material
		_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_particles, false, Node.INTERNAL_MODE_BACK)


func _exit_tree() -> void:
	remove_from_group(&"surface_displacement_scatter")


## The window's cells per side for the current radius.
func get_window_cells() -> int:
	return 2 * ceili(radius / cell_size) + 1


## Particles in use (window cells^2 x per_cell).
func get_slot_count() -> int:
	var n := get_window_cells()
	return n * n * per_cell


func get_particles() -> GPUParticles3D:
	return _particles


func _process(_delta: float) -> void:
	var field := get_parent() as DisplacementField3D
	if field == null or _particles == null:
		return
	var cam := field._find_camera()
	if cam == null:
		return
	if _dirty:
		_dirty = false
		_particles.amount = get_slot_count()
		_process_material.set_shader_parameter("window_cells", get_window_cells())
		_process_material.set_shader_parameter("per_cell", per_cell)
		_process_material.set_shader_parameter("cell_size", cell_size)
		_process_material.set_shader_parameter("radius", radius)
		_process_material.set_shader_parameter("density", density)
		_process_material.set_shader_parameter("size_range", size_range)
		_process_material.set_shader_parameter("valley_bias", valley_bias)
		_process_material.set_shader_parameter("layer_density", layer_density)
	var source := field.get_material()
	for name: String in COPIED_FROM_FIELD:
		_process_material.set_shader_parameter(name, source.get_shader_parameter(name))
	for name: String in COPIED_TO_PEBBLES:
		_pebble_material.set_shader_parameter(name, source.get_shader_parameter(name))
	var p := cam.global_position
	var half := ceili(radius / cell_size)
	var first := Vector2(floorf(p.x / cell_size) - half, floorf(p.z / cell_size) - half)
	_process_material.set_shader_parameter("window_cell", first)
	_process_material.set_shader_parameter("camera_position", p)
	var extent := (half + 1) * cell_size
	_particles.global_transform = Transform3D(Basis.IDENTITY, Vector3(p.x, 0.0, p.z))
	var range_y := Vector2(p.y - 50.0, 100.0)
	_particles.visibility_aabb = AABB(Vector3(-extent, range_y.x, -extent), Vector3(2.0 * extent, range_y.y, 2.0 * extent))


## A pebble: an icosphere subdivided [param subdivisions] times (1 = 80 triangles) with smooth
## low-frequency noise on the radius, unit size (radius about 0.5).
static func make_pebble_mesh(subdivisions: int, seed_value := 11) -> ArrayMesh:
	var t := (1.0 + sqrt(5.0)) / 2.0
	var verts := PackedVector3Array([
		Vector3(-1, t, 0), Vector3(1, t, 0), Vector3(-1, -t, 0), Vector3(1, -t, 0),
		Vector3(0, -1, t), Vector3(0, 1, t), Vector3(0, -1, -t), Vector3(0, 1, -t),
		Vector3(t, 0, -1), Vector3(t, 0, 1), Vector3(-t, 0, -1), Vector3(-t, 0, 1)])
	var faces := PackedInt32Array([0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4,
		11, 10, 2, 10, 7, 6, 7, 1, 8, 3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11,
		6, 2, 10, 8, 6, 7, 9, 8, 1])
	for i in verts.size():
		verts[i] = verts[i].normalized()
	for s in subdivisions:
		var mid := {}
		var next := PackedInt32Array()
		for f in range(0, faces.size(), 3):
			var m := []
			for e in 3:
				var a := faces[f + e]
				var b := faces[f + (e + 1) % 3]
				var key := Vector2i(mini(a, b), maxi(a, b))
				if not mid.has(key):
					mid[key] = verts.size()
					verts.append(((verts[a] + verts[b]) * 0.5).normalized())
				m.append(mid[key])
			next.append_array(PackedInt32Array([faces[f], m[0], m[2], faces[f + 1], m[1], m[0], faces[f + 2], m[2], m[1], m[0], m[1], m[2]]))
		faces = next
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.frequency = 1.3
	for i in verts.size():
		verts[i] = verts[i] * 0.5 * (1.0 + 0.22 * noise.get_noise_3dv(verts[i] * 1.7))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# White vertex colours: the particle colour (the per-pebble tint) is multiplied with them.
	st.set_color(Color.WHITE)
	# Icosphere faces wind counter-clockwise from outside; Godot's front faces are clockwise.
	for f in range(0, faces.size(), 3):
		for e in [0, 2, 1]:
			st.add_vertex(verts[faces[f + e]])
	st.index()
	st.generate_normals()
	return st.commit()
