extends RefCounted
## Helpers shared by the render tests, the benchmark and the measurement tools: an HDR SubViewport
## (linear float read-back, so debug outputs are exact), scene setup, synthetic height fields
## and a CPU reference for the ray / height-field intersection.

const DEBUG_OFF := 0
const DEBUG_HIT_OFFSET := 1
const DEBUG_COST := 2
const DEBUG_RELIEF := 3
const DEBUG_NORMAL := 4
const DEBUG_SELF_SHADOW := 5
const DEBUG_WORLD_HEIGHT := 6
const DEBUG_WHITE := 7
const DEBUG_LEVELS := 8

var tree: SceneTree
var viewport: SubViewport
var scene: Node3D


func _init(p_tree: SceneTree) -> void:
	tree = p_tree


## A SubViewport of [param size]. [param hdr]: RGBA16F linear output (debug read-back); false:
## the ordinary 8-bit sRGB output a player sees.
func make_viewport(size: Vector2i, hdr := true) -> SubViewport:
	if viewport == null:
		viewport = SubViewport.new()
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		tree.root.add_child(viewport)
	viewport.size = size
	viewport.use_hdr_2d = hdr
	return viewport


func frames(n: int) -> void:
	for i in n:
		await tree.process_frame


## The viewport image after the next frame has been drawn.
func capture() -> Image:
	await tree.process_frame
	await RenderingServer.frame_post_draw
	return viewport.get_texture().get_image()


func clear_scene() -> void:
	if scene != null:
		scene.queue_free()
		scene = null


## An empty scene with an environment that passes EMISSION through unchanged: black background,
## no ambient light, linear tone mapping, no glow, fog or SSAO.
func new_debug_scene() -> Node3D:
	clear_scene()
	scene = Node3D.new()
	scene.name = "TestScene"
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0, 0, 0)
	env.ambient_light_energy = 0.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_exposure = 1.0
	we.environment = env
	scene.add_child(we)
	viewport.add_child(scene)
	return scene


## A scene lit by [param ambient] (flat colour, no sky) with linear tone mapping and nothing else
## (no SSAO, glow or fog), so pixel values are directly comparable between renders.
func new_lit_scene(ambient := Color(0.2, 0.2, 0.2)) -> Node3D:
	var s := new_debug_scene()
	var env := (s.get_child(0) as WorldEnvironment).environment
	env.ambient_light_color = ambient
	env.ambient_light_energy = 1.0
	return s


func add_sun(elevation_deg: float, azimuth_deg: float, shadows := true, max_distance := 20.0) -> DirectionalLight3D:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-elevation_deg, azimuth_deg, 0.0)
	sun.shadow_enabled = shadows
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = max_distance
	scene.add_child(sun)
	return sun


## Unit vector towards a directional light (the opposite of its forward -Z).
static func light_direction(light: DirectionalLight3D) -> Vector3:
	return light.global_transform.basis.z.normalized()


func add_camera(from: Vector3, to: Vector3, fov := 60.0, up := Vector3.UP) -> Camera3D:
	var cam := Camera3D.new()
	cam.fov = fov
	cam.near = 0.02
	cam.far = 200.0
	scene.add_child(cam)
	cam.look_at_from_position(from, to, up)
	cam.current = true
	return cam


## A quad with corners a, b, c, d (counter-clockwise seen from the front, i.e. its normal is
## (b - a) x (c - a)) and UVs uv_a..uv_d, with normals and tangents, as a MeshInstance3D in the
## scene. Godot's front faces wind clockwise on screen, so the triangles are emitted reversed.
func add_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, uvs: Array, material: Material) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := (b - a).cross(c - a).normalized()
	var pts := [a, b, c, d]
	for i in [0, 2, 1, 0, 3, 2]:
		st.set_normal(n)
		st.set_uv(uvs[i])
		st.add_vertex(pts[i])
	st.generate_tangents()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = material
	scene.add_child(mi)
	return mi


# --- Height fields ---------------------------------------------------------------------------

## A tileable "stones" height field: rounded bumps with steep sides on a flat base (the kind of
## relief where a linear search alone misses). Returns {"image": Image (RH, mipmapped),
## "data": PackedFloat32Array (row-major, mip 0, the values the GPU sees), "size": int}.
static func make_stone_field(size: int, count: int, seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var data := PackedFloat32Array()
	data.resize(size * size)
	for i in count:
		var cx := rng.randf() * size
		var cy := rng.randf() * size
		var radius := rng.randf_range(0.025, 0.07) * size
		var top := rng.randf_range(0.55, 1.0)
		# Only the stone's bounding box, wrapped around the tile edges.
		for py in range(floori(cy - radius), ceili(cy + radius) + 1):
			for px in range(floori(cx - radius), ceili(cx + radius) + 1):
				var dx := (px + 0.5) - cx
				var dy := (py + 0.5) - cy
				var r := sqrt(dx * dx + dy * dy) / radius
				if r >= 1.0:
					continue
				var r2 := r * r
				var index := posmod(py, size) * size + posmod(px, size)
				data[index] = maxf(data[index], top * sqrt(1.0 - r2 * r2))
	return field_from_data(data, size)


## A smooth tileable field (sums of sines), for tests that should not depend on refinement.
static func make_wave_field(size: int) -> Dictionary:
	var data := PackedFloat32Array()
	data.resize(size * size)
	for y in size:
		for x in size:
			var u := TAU * (x + 0.5) / size
			var v := TAU * (y + 0.5) / size
			data[y * size + x] = 0.5 + 0.25 * sin(2.0 * u) * cos(3.0 * v) + 0.2 * sin(5.0 * u + v)
	return field_from_data(data, size)


static func field_from_data(data: PackedFloat32Array, size: int) -> Dictionary:
	var img := Image.create(size, size, false, Image.FORMAT_RF)
	for y in size:
		for x in size:
			img.set_pixel(x, y, Color(data[y * size + x], 0, 0))
	img.convert(Image.FORMAT_RH)
	# Read back the half-float values: those are what the GPU samples.
	var stored := PackedFloat32Array()
	stored.resize(size * size)
	for y in size:
		for x in size:
			stored[y * size + x] = img.get_pixel(x, y).r
	img.generate_mipmaps()
	return {"image": img, "data": stored, "size": size}


## Bilinear sample of field mip 0 with wrap-around, like a repeat_enable linear sampler.
static func sample_field(field: Dictionary, uv: Vector2) -> float:
	var size: int = field["size"]
	var data: PackedFloat32Array = field["data"]
	var x := uv.x * size - 0.5
	var y := uv.y * size - 0.5
	var x0 := floori(x)
	var y0 := floori(y)
	var fx := x - x0
	var fy := y - y0
	var xa := posmod(x0, size)
	var xb := posmod(x0 + 1, size)
	var ya := posmod(y0, size)
	var yb := posmod(y0 + 1, size)
	var a := data[ya * size + xa]
	var b := data[ya * size + xb]
	var c := data[yb * size + xa]
	var d := data[yb * size + xb]
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy)


## First intersection of the ray origin + t * dir with a height field over a flat base plane.
## [param surface]: {"point": Vector3 on the base plane, "normal": base normal N, "axis": relief
## axis A, "uv": Callable(Vector3 foot point) -> Vector2, "amp": metres, "center": 0..1,
## "field": the field}. Relief z = amp * (h - center) along A. Returns {"hit": Vector3,
## "raster": Vector3 (ray at the base plane)} or {} if the ray misses the slab.
static func trace_height_field(origin: Vector3, dir: Vector3, surface: Dictionary, step_m := 0.0002) -> Dictionary:
	var n: Vector3 = surface["normal"]
	var a: Vector3 = surface["axis"]
	var p0: Vector3 = surface["point"]
	var amp: float = surface["amp"]
	var center: float = surface["center"]
	var na := n.dot(a)
	var nd := n.dot(dir)
	if nd >= -1e-6:
		return {}
	# z_ray(t) = n.(origin + t dir - p0) / (n.a)
	var z0 := n.dot(origin - p0) / na
	var dz_dt := nd / na
	var z_top := (1.0 - center) * amp
	var z_bot := -center * amp
	var t_top := (z_top - z0) / dz_dt
	var t_bot := (z_bot - z0) / dz_dt
	var t_raster := -z0 / dz_dt
	var steps := maxi(ceili(absf(z_top - z_bot) / step_m), 1)
	var dt := (t_bot - t_top) / steps
	var t_prev := t_top
	var t_hit := t_bot
	if _ray_minus_relief(origin, dir, t_top, surface) > 0.0:
		for i in range(1, steps + 1):
			var t := t_top + dt * i
			if _ray_minus_relief(origin, dir, t, surface) <= 0.0:
				var lo := t_prev
				var hi := t
				for k in 40:
					var mid := 0.5 * (lo + hi)
					if _ray_minus_relief(origin, dir, mid, surface) <= 0.0:
						hi = mid
					else:
						lo = mid
				t_hit = 0.5 * (lo + hi)
				break
			t_prev = t
	else:
		t_hit = t_top
	return {"hit": origin + dir * t_hit, "raster": origin + dir * t_raster}


## Height of the ray point above the relief, along the relief axis (negative = below).
static func _ray_minus_relief(origin: Vector3, dir: Vector3, t: float, surface: Dictionary) -> float:
	var n: Vector3 = surface["normal"]
	var a: Vector3 = surface["axis"]
	var r := origin + dir * t
	var z := n.dot(r - (surface["point"] as Vector3)) / n.dot(a)
	var foot := r - a * z
	var uv: Vector2 = (surface["uv"] as Callable).call(foot)
	var amp: float = surface["amp"]
	return z - amp * (sample_field(surface["field"], uv) - float(surface["center"]))


## Relief height (m) of [param surface] (see trace_height_field) at foot point [param p].
static func relief_at(surface: Dictionary, p: Vector3) -> float:
	var uv: Vector2 = (surface["uv"] as Callable).call(p)
	return float(surface["amp"]) * (sample_field(surface["field"], uv) - float(surface["center"]))


## Whether the height field of [param surface] blocks the ray from surface point [param from]
## (on the relief) towards the unit direction [param to_light]; marched in steps of 0.2 mm of
## relief height up to the top of the slab.
static func height_field_shadowed(from: Vector3, to_light: Vector3, surface: Dictionary, bias: float) -> bool:
	var n: Vector3 = surface["normal"]
	var a: Vector3 = surface["axis"]
	var na := n.dot(a)
	var rate := n.dot(to_light) / na
	if rate <= 0.0:
		return false
	var z0 := n.dot(from - (surface["point"] as Vector3)) / na
	var z_top := (1.0 - float(surface["center"])) * float(surface["amp"])
	var steps := ceili((z_top - z0) / 0.0002)
	for i in range(1, steps + 1):
		var z := z0 + (z_top - z0) * i / steps
		var r := from + to_light * ((z - z0) / rate)
		var foot := r - a * z
		if relief_at(surface, foot) - z > bias:
			return true
	return false


## Mip [param level] of a field made by field_from_data, as {"data", "size"} for sample_field.
static func field_mip(field: Dictionary, level: int) -> Dictionary:
	var img: Image = field["image"]
	var size: int = int(field["size"]) >> level
	var mip := Image.create_from_data(size, size, false, img.get_format(),
			img.get_data().slice(img.get_mipmap_offset(level), img.get_mipmap_offset(level) + size * size * 2))
	var data := PackedFloat32Array()
	data.resize(size * size)
	for y in size:
		for x in size:
			data[y * size + x] = mip.get_pixel(x, y).r
	return {"data": data, "size": size}


## Decodes debug view 1 (hit offset, world space) at pixel p.
static func decode_offset(img: Image, p: Vector2i, scale: float) -> Vector3:
	var c := img.get_pixelv(p)
	return (Vector3(c.r, c.g, c.b) - Vector3(0.5, 0.5, 0.5)) * (2.0 * scale)


static func luminance(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
