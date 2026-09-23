@tool
class_name SDGroundBake
extends Resource
## The ground under a [DisplacementField3D]: world height and field-layer weights on a regular
## grid, captured once from above.
##
## [method bake] renders the meshes of a ground group into an orthographic top-down SubViewport of
## its own World3D (so nothing else in the scene is captured: no tunnel roofs, overhangs or
## props). Each surface writes its world height (16-bit fixed point over the bake's height range)
## and which field layer its material is. Save the result as a resource (.res) from the editor;
## a field without one bakes at runtime.

## Height of the ground (m) at texel centres, [constant Image.FORMAT_RF].
@export var height: Image
## Coverage of field layers 0-3 (RGBA), [constant Image.FORMAT_RGBA8].
@export var weights: Image
## World XZ of the corner of texel (0, 0).
@export var origin := Vector2.ZERO
## Texel size in metres.
@export var texel_size := 0.05
## The layer materials the weights refer to, in order (resource paths or names), for validation.
@export var layer_names := PackedStringArray()

const CAPTURE_SHADER := preload("res://addons/surface_displacement/shaders/sd_ground_capture.gdshader")
const TILE_PX := 2048


func get_size() -> Vector2i:
	return Vector2i.ZERO if height == null else height.get_size()


func get_rect() -> Rect2:
	return Rect2(origin, Vector2(get_size()) * texel_size)


## Minimum and maximum baked height.
func get_height_range() -> Vector2:
	if height == null:
		return Vector2.ZERO
	var data := height.get_data().to_float32_array()
	var lo := INF
	var hi := -INF
	for v in data:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	return Vector2(lo, hi)


## Height at world [param xz]: bilinear between texel centres, clamped to the bake, exactly as the
## field's vertex shader computes it (sd_ground_at).
func sample_height(xz: Vector2) -> float:
	var size := get_size()
	var t := ((xz - origin) / texel_size - Vector2(0.5, 0.5)).clamp(Vector2.ZERO, Vector2(size) - Vector2.ONE)
	var i0 := Vector2i(floori(t.x), floori(t.y))
	var i1 := Vector2i(mini(i0.x + 1, size.x - 1), mini(i0.y + 1, size.y - 1))
	var f := t - Vector2(i0)
	var a := height.get_pixel(i0.x, i0.y).r
	var b := height.get_pixel(i1.x, i0.y).r
	var c := height.get_pixel(i0.x, i1.y).r
	var d := height.get_pixel(i1.x, i1.y).r
	return lerpf(lerpf(a, b, f.x), lerpf(c, d, f.x), f.y)


## Layer weights at world [param xz] (nearest texel).
func sample_weights(xz: Vector2) -> Color:
	var size := get_size()
	var p := ((xz - origin) / texel_size).floor()
	var i := Vector2i(clampi(int(p.x), 0, size.x - 1), clampi(int(p.y), 0, size.y - 1))
	return weights.get_pixel(i.x, i.y)


## The MeshInstance3D nodes of [param group] in [param tree] (members and their descendants).
static func collect_ground(tree: SceneTree, group: StringName) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for node in tree.get_nodes_in_group(group):
		if node is MeshInstance3D and not out.has(node):
			out.append(node)
		for child in node.find_children("*", "MeshInstance3D", true, false):
			if not out.has(child):
				out.append(child)
	return out


## Index of the field layer [param material] is (same resource), or -1.
static func layer_index(material: Material, layers: Array) -> int:
	for i in layers.size():
		if layers[i] != null and layers[i] == material:
			return i
	return -1


## The material that shades surface [param surface] of [param mi].
static func surface_material(mi: MeshInstance3D, surface: int) -> Material:
	if mi.material_override != null:
		return mi.material_override
	var m := mi.get_surface_override_material(surface)
	if m != null:
		return m
	return mi.mesh.surface_get_material(surface) if mi.mesh != null else null


## Captures [param meshes] from above into a new bake (coroutine: await it). Must run with a
## rendering device (not --headless). [param layers]: the field's layer materials.
## [param bounds]: the XZ rectangle to capture; empty = the meshes' bounds.
## [param step_limit]: a height change larger than this between neighbouring texels (a kerb, a
## step) is not a height field; the texels on both sides are marked not displaceable, so the
## field dives under the ground there instead of draping a ramp over the step.
static func bake(meshes: Array[MeshInstance3D], layers: Array, texel: float, bounds := Rect2(), step_limit := 0.04) -> SDGroundBake:
	if meshes.is_empty():
		push_warning("SDGroundBake: nothing to bake (no ground meshes).")
		return null
	if RenderingServer.get_rendering_device() == null:
		push_warning("SDGroundBake: baking needs a rendering device (the ground stays flat); not available with --headless.")
		return null
	var tree := meshes[0].get_tree()
	var aabb := AABB()
	var first := true
	for mi in meshes:
		var box := mi.global_transform * mi.get_aabb()
		aabb = box if first else aabb.merge(box)
		first = false
	if bounds.has_area():
		aabb.position.x = bounds.position.x
		aabb.position.z = bounds.position.y
		aabb.size.x = bounds.size.x
		aabb.size.z = bounds.size.y
	var size := Vector2i(maxi(ceili(aabb.size.x / texel), 1), maxi(ceili(aabb.size.z / texel), 1))
	var h_min := aabb.position.y - 0.01
	var h_range := maxf(aabb.size.y + 0.02, 0.01)

	var vp := SubViewport.new()
	vp.own_world_3d = true
	vp.transparent_bg = true
	vp.use_hdr_2d = true
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	we.environment = env
	vp.add_child(we)
	var materials := []
	for i in 5:
		var m := ShaderMaterial.new()
		m.shader = CAPTURE_SHADER
		m.set_shader_parameter("height_min", h_min)
		m.set_shader_parameter("height_range", h_range)
		m.set_shader_parameter("layer_code", float(i) / 8.0)
		materials.append(m)
	for mi in meshes:
		if mi.mesh == null:
			continue
		var copy := MeshInstance3D.new()
		copy.mesh = mi.mesh
		copy.skeleton = NodePath()
		for s in mi.mesh.get_surface_count():
			copy.set_surface_override_material(s, materials[layer_index(surface_material(mi, s), layers) + 1])
		# Direct children of the SubViewport: their transform is their global transform.
		copy.transform = mi.global_transform
		vp.add_child(copy)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.near = 0.05
	cam.far = h_range + 2.0
	vp.add_child(cam)
	tree.root.add_child(vp)

	var result := SDGroundBake.new()
	result.texel_size = texel
	result.origin = Vector2(aabb.position.x, aabb.position.z)
	for layer in layers:
		result.layer_names.append(layer.resource_path if layer != null and not layer.resource_path.is_empty() else str(layer))
	var heights := PackedFloat32Array()
	heights.resize(size.x * size.y)
	var weight_bytes := PackedByteArray()
	weight_bytes.resize(size.x * size.y * 4)
	var covered := PackedByteArray()
	covered.resize(size.x * size.y)
	for ty in range(0, size.y, TILE_PX):
		for tx in range(0, size.x, TILE_PX):
			var tile := Vector2i(mini(TILE_PX, size.x - tx), mini(TILE_PX, size.y - ty))
			vp.size = tile
			# Looking down -Y with -Z up: image right = +X, image down = +Z.
			var centre := Vector3(aabb.position.x + (tx + tile.x * 0.5) * texel, h_min + h_range + 1.0,
					aabb.position.z + (ty + tile.y * 0.5) * texel)
			cam.size = tile.y * texel
			cam.global_transform = Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)), centre)
			cam.current = true
			for i in 3:
				await tree.process_frame
			await RenderingServer.frame_post_draw
			var img := vp.get_texture().get_image()
			img.convert(Image.FORMAT_RGBAF)
			var px := img.get_data().to_float32_array()
			for y in tile.y:
				for x in tile.x:
					var o := (y * tile.x + x) * 4
					if px[o + 3] < 0.5:
						continue
					var g := (ty + y) * size.x + tx + x
					heights[g] = h_min + (roundf(px[o] * 255.0) * 256.0 + roundf(px[o + 1] * 255.0)) / 65535.0 * h_range
					var code := roundi(px[o + 2] * 8.0)
					if code >= 1 and code <= 4:
						weight_bytes[g * 4 + code - 1] = 255
					covered[g] = 1
	vp.queue_free()
	_mark_steps(heights, covered, weight_bytes, size, step_limit)
	_fill_uncovered(heights, covered, size)
	result.height = Image.create_from_data(size.x, size.y, false, Image.FORMAT_RF, heights.to_byte_array())
	result.weights = Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, weight_bytes)
	return result


## Clears the layer weights of texels next to a height step larger than [param limit] (and of
## texels next to no ground at all).
static func _mark_steps(heights: PackedFloat32Array, covered: PackedByteArray, weights: PackedByteArray, size: Vector2i, limit: float) -> void:
	var clear := PackedByteArray()
	clear.resize(size.x * size.y)
	for y in size.y:
		for x in size.x:
			var i := y * size.x + x
			if covered[i] == 0:
				continue
			for d: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
				var nx := x + d.x
				var ny := y + d.y
				if nx >= size.x or ny >= size.y:
					continue
				var j := ny * size.x + nx
				if covered[j] == 0 or absf(heights[i] - heights[j]) > limit:
					clear[i] = 1
					clear[j] = 1
	for i in clear.size():
		if clear[i] != 0:
			for c in 4:
				weights[i * 4 + c] = 0


## Gives texels without ground the height of their covered neighbours (repeated one-texel
## dilation), so the bilinear lookup stays sane at the ground's edges.
static func _fill_uncovered(heights: PackedFloat32Array, covered: PackedByteArray, size: Vector2i) -> void:
	if covered.find(1) < 0:
		return
	var remaining := true
	while remaining:
		remaining = false
		var next := covered.duplicate()
		for y in size.y:
			for x in size.x:
				var i := y * size.x + x
				if covered[i] != 0:
					continue
				var sum := 0.0
				var n := 0
				if x > 0 and covered[i - 1] != 0:
					sum += heights[i - 1]
					n += 1
				if x < size.x - 1 and covered[i + 1] != 0:
					sum += heights[i + 1]
					n += 1
				if y > 0 and covered[i - size.x] != 0:
					sum += heights[i - size.x]
					n += 1
				if y < size.y - 1 and covered[i + size.x] != 0:
					sum += heights[i + size.x]
					n += 1
				if n > 0:
					heights[i] = sum / n
					next[i] = 1
				else:
					remaining = true
		covered = next
