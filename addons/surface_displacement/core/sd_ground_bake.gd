@tool
class_name SDGroundBake
extends Resource
## The ground under a [DisplacementField3D]: world height and field layer on a regular grid,
## captured once from above.
##
## [method bake] renders the meshes of a ground group into an orthographic top-down SubViewport of
## its own World3D (so nothing else in the scene is captured: no tunnel roofs, overhangs or
## props). Each surface writes its world height (16-bit fixed point over the bake's height range)
## and which field layer its material is. The image is stored as captured; the field's shaders
## (sd_ground.gdshaderinc) and [method sample] decode it, decide which texels are displaceable
## (covered, and no step to a neighbour higher than [member step_limit]) and interpolate. Save
## the result as a resource (.res) from the editor; a field without one bakes at runtime.

## One texel per cell, [constant Image.FORMAT_RGBAH]: R, G = height high and low byte / 255, B =
## layer code (field layer i + 1) / 8 (0 = ground that is none of the layers), A = 1 where a
## ground mesh covered the cell.
@export var data: Image
## World XZ of the corner of texel (0, 0).
@export var origin := Vector2.ZERO
## Texel size in metres.
@export var texel_size := 0.05
## The encoded heights span [height_min, height_min + height_range] (m).
@export var height_min := 0.0
@export var height_range := 1.0
## A texel whose neighbour's height differs by more than this (m) is at a step (a kerb), not on a
## height field: it is not displaceable.
@export var step_limit := 0.04
## The layer materials the codes refer to, in order (resource paths or names), for validation.
@export var layer_names := PackedStringArray()

const CAPTURE_SHADER := preload("res://addons/surface_displacement/shaders/sd_ground_capture.gdshader")
const TILE_PX := 2048
## Default steepest slope (rise / run between neighbouring texels) that still counts as ground:
## 0.8 is 38.7 degrees, whatever the texel size.
const STEP_SLOPE := 0.8


func get_size() -> Vector2i:
	return Vector2i.ZERO if data == null else data.get_size()


func get_rect() -> Rect2:
	return Rect2(origin, Vector2(get_size()) * texel_size)


## The range the heights are encoded in (m): at least the ground's lowest and highest point.
func get_height_range() -> Vector2:
	return Vector2(height_min, height_min + height_range)


## Height (m), normal and field-layer weights at world [param xz], exactly as the field's shaders
## compute them (sd_ground.gdshaderinc): {"height": float, "normal": Vector3, "weights": Color}.
func sample(xz: Vector2) -> Dictionary:
	var size := get_size()
	var t := (xz - origin) / texel_size - Vector2(0.5, 0.5)
	var i0 := Vector2i(floori(t.x), floori(t.y))
	var f := t - Vector2(i0)
	var h := PackedFloat64Array()
	h.resize(16)
	var covered: Array[bool] = []
	covered.resize(16)
	var code := PackedInt32Array()
	code.resize(16)
	var covered_sum := 0.0
	var covered_count := 0
	for k in 16:
		var p := i0 + Vector2i(k % 4 - 1, k / 4 - 1)
		var pc := p.clamp(Vector2i.ZERO, size - Vector2i.ONE)
		var d := data.get_pixel(pc.x, pc.y)
		h[k] = height_min + (roundf(d.r * 255.0) * 256.0 + roundf(d.g * 255.0)) / 65535.0 * height_range
		covered[k] = p == pc and d.a > 0.5
		code[k] = roundi(d.b * 8.0)
		if covered[k]:
			covered_sum += h[k]
			covered_count += 1
	var fill := covered_sum / covered_count if covered_count > 0 else h[5]
	for k in 16:
		if not covered[k]:
			h[k] = fill
	var w: Array[Color] = []
	var gradient: Array[Vector2] = []
	for c: int in [5, 6, 9, 10]:
		var ok := covered[c]
		for n: int in [c - 1, c + 1, c - 4, c + 4]:
			ok = ok and covered[n] and absf(h[n] - h[c]) <= step_limit
		var one_hot := Color(0, 0, 0, 0)
		if ok and code[c] >= 1 and code[c] <= 4:
			one_hot[code[c] - 1] = 1.0
		w.append(one_hot)
		gradient.append(Vector2(h[c + 1] - h[c - 1], h[c + 4] - h[c - 4]) / (2.0 * texel_size))
	var slope := gradient[0].lerp(gradient[1], f.x).lerp(gradient[2].lerp(gradient[3], f.x), f.y)
	return {
		"height": lerpf(lerpf(h[5], h[6], f.x), lerpf(h[9], h[10], f.x), f.y),
		"normal": Vector3(-slope.x, 1.0, -slope.y).normalized(),
		"weights": w[0].lerp(w[1], f.x).lerp(w[2].lerp(w[3], f.x), f.y),
	}


## Ground height (m) at world [param xz], see [method sample].
func sample_height(xz: Vector2) -> float:
	return sample(xz)["height"]


## Field-layer weights (r = layer 0 ...) at world [param xz], see [method sample].
func sample_weights(xz: Vector2) -> Color:
	return sample(xz)["weights"]


## A bake from arrays, e.g. procedural terrain (row-major, [param size].x values per row, row 0
## at [param origin_xz].y): [param heights] in metres, [param layers] the field layer of each
## cell (-1 = ground that is none of the layers, -2 = no ground).
static func from_arrays(size: Vector2i, heights: PackedFloat32Array, layers: PackedInt32Array, origin_xz: Vector2,
		texel: float, step_slope := STEP_SLOPE) -> SDGroundBake:
	var result := SDGroundBake.new()
	result.origin = origin_xz
	result.texel_size = texel
	result.step_limit = step_slope * texel
	var lo := INF
	var hi := -INF
	for v in heights:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	result.height_min = lo - 0.01
	result.height_range = maxf(hi - lo + 0.02, 0.01)
	result.data = Image.create(size.x, size.y, false, Image.FORMAT_RGBAH)
	for y in size.y:
		for x in size.x:
			var i := y * size.x + x
			if layers[i] <= -2:
				continue
			var q := roundi((heights[i] - result.height_min) / result.height_range * 65535.0)
			result.data.set_pixel(x, y, Color((q >> 8) / 255.0, (q & 255) / 255.0, (layers[i] + 1) / 8.0, 1.0))
	return result


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
## [param step_slope]: a height change between neighbouring texels steeper than this (rise / run)
## is a step (a kerb), not ground to displace; see [member step_limit].
## It renders a few frames per 2048 x 2048 tile; nothing is processed per texel on the CPU.
static func bake(meshes: Array[MeshInstance3D], layers: Array, texel: float, bounds := Rect2(), step_slope := STEP_SLOPE) -> SDGroundBake:
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
	# In the editor the capture lives in the editor's own UI, outside the edited scene (nodes
	# added inside it or to the editor's root window trip up the inspector and undo history
	# later); in a running game, under the root. Deferred: a field that bakes in _ready() runs
	# while its ancestors are still adding children, and the root refuses new children then.
	var editor := Engine.get_singleton(&"EditorInterface") if Engine.is_editor_hint() else null
	var parent: Node = editor.get_base_control() if editor != null else tree.root
	parent.add_child.call_deferred(vp)

	var result := SDGroundBake.new()
	result.texel_size = texel
	result.origin = Vector2(aabb.position.x, aabb.position.z)
	result.height_min = h_min
	result.height_range = h_range
	result.step_limit = step_slope * texel
	for layer in layers:
		result.layer_names.append(layer.resource_path if layer != null and not layer.resource_path.is_empty() else str(layer))
	result.data = Image.create(size.x, size.y, false, Image.FORMAT_RGBAH)
	for ty in range(0, size.y, TILE_PX):
		for tx in range(0, size.x, TILE_PX):
			var tile := Vector2i(mini(TILE_PX, size.x - tx), mini(TILE_PX, size.y - ty))
			vp.size = tile
			# Looking down -Y with -Z up: image right = +X, image down = +Z.
			var centre := Vector3(aabb.position.x + (tx + tile.x * 0.5) * texel, h_min + h_range + 1.0,
					aabb.position.z + (ty + tile.y * 0.5) * texel)
			cam.size = tile.y * texel
			# The only camera in the SubViewport is current by itself. (Setting `current` in the
			# editor registers it with the editor's camera preview, which later trips over the
			# freed camera.) A direct child of the SubViewport: its transform is its global one.
			cam.transform = Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)), centre)
			for i in 3:
				await tree.process_frame
			await RenderingServer.frame_post_draw
			var img := vp.get_texture().get_image()
			if img.get_format() != Image.FORMAT_RGBAH:
				img.convert(Image.FORMAT_RGBAH)
			result.data.blit_rect(img, Rect2i(Vector2i.ZERO, tile), Vector2i(tx, ty))
	vp.queue_free()
	return result
