extends SceneTree
## Headed render tests (--headless is a dummy renderer that draws nothing):
##     python tools/godot.py --script tests/render_tests.gd
## Every test renders into SubViewports and compares against an exact reference where one exists
## (a CPU ray / height-field intersection, real displaced geometry, the height map itself,
## Godot's own shading). Exit code 0 = all passed. Measured values are printed so the README can
## quote them. Run a subset with: python tools/godot.py --script tests/render_tests.gd -- --only=name,name

const Harness := preload("res://tests/lib/sd_harness.gd")
const SIZE := Vector2i(960, 540)
const OFFSET_SCALE := 0.1

var h: Harness
var _passed := 0
var _failed := 0


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	SDGlobals.ensure_registered()
	h = Harness.new(self)
	h.make_viewport(SIZE, true)
	_run()


func _run() -> void:
	await _test("emission_passthrough", test_emission_passthrough)
	await _test("globals_and_parameter_defaults", test_globals_and_defaults)
	await _test("pom_matches_ray_traced_height_field", test_pom_vs_reference)
	await _test("inverted_height_remap", test_height_remap)
	await _test("world_planar_on_walls_stays_finite", test_world_planar_walls)
	await _test("pom_relief_does_not_swim", test_pom_no_swimming)
	await _test("triplanar_skips_zero_weight_planes", test_triplanar_planes)
	await _test("light_function_matches_godot", test_brdf_parity)
	await _test("light_vertex_moves_shadows_onto_relief", test_light_vertex)
	await _test("self_shadow_matches_height_field", test_self_shadow)
	await _test("depth_write_opt_in", test_depth_write)
	await _test("mip_shimmer_at_distance", test_mip_shimmer)
	await _test("relief_fades_with_distance", test_distance_fade)
	print("\nrender tests: %d passed, %d failed" % [_passed, _failed])
	h.clear_scene()
	h.viewport.queue_free()
	await h.frames(3)
	quit(1 if _failed > 0 else 0)


func _test(test_name: String, fn: Callable) -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			var wanted := false
			for part in arg.trim_prefix("--only=").split(","):
				wanted = wanted or test_name.contains(part)
			if not wanted:
				return
	print("\n== %s" % test_name)
	_reset_globals()
	await fn.call()


func check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("  ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL %s" % what)


## Medium quality, no fade, mip 0 forced (LOD bias -10), self-shadow off, debug off.
func _reset_globals() -> void:
	set_quality(8, 24, 3)
	SDGlobals.set_value(SDGlobals.POM_RANGE, Vector4(1000, 2000, -10, 99))
	SDGlobals.set_value(SDGlobals.SHADOW, Vector4(8, 20, 0, 0))
	SDGlobals.set_value(SDGlobals.DEBUG, Vector4(0, OFFSET_SCALE, 0, 0))


func set_quality(min_steps: int, max_steps: int, refine: int) -> void:
	SDGlobals.set_value(SDGlobals.POM_STEPS, Vector4(min_steps, max_steps, refine, 0))


func debug_view(view: int) -> void:
	SDGlobals.set_value(SDGlobals.DEBUG, Vector4(view, OFFSET_SCALE, 0, 0))


static func percentile(values: Array, q: float) -> float:
	if values.is_empty():
		return INF
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[clampi(int(q * (sorted.size() - 1) + 0.5), 0, sorted.size() - 1)]


# --- 1. The debug read-back is exact --------------------------------------------------------

func test_emission_passthrough() -> void:
	h.new_debug_scene()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.25, 0.5, 0.75)
	var q := h.add_quad(Vector3(-1, -1, 0), Vector3(1, -1, 0), Vector3(1, 1, 0), Vector3(-1, 1, 0),
			[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)], mat)
	h.add_camera(Vector3(0, 0, 1), Vector3.ZERO)
	await h.frames(5)
	var img := await h.capture()
	var c := img.get_pixel(SIZE.x / 2, SIZE.y / 2)
	print("  format %d, centre %s" % [img.get_format(), c])
	check(img.get_format() == Image.FORMAT_RGBH or img.get_format() == Image.FORMAT_RGBAH, "HDR viewport reads back as half floats")
	# Unshaded albedo is sRGB-converted to linear once (source colour), then written unchanged.
	var expected := Color(0.25, 0.5, 0.75).srgb_to_linear()
	check(absf(c.r - expected.r) < 2e-3 and absf(c.g - expected.g) < 2e-3 and absf(c.b - expected.b) < 2e-3,
			"a known colour reads back within half-float precision (%s vs %s)" % [c, expected])
	q.queue_free()


# --- 2. POM against the exact ray / height-field intersection --------------------------------

## Surfaces: [name, mapping, corners (a, b, c, d), relief axis, uv Callable(foot point), extra
## shader parameters]. Their uv functions follow the documented conventions (sd_core.gdshaderinc)
## and are written here independently of the shader.
func _surfaces(tile: float) -> Array:
	var rot := deg_to_rad(30.0)
	var off := Vector2(0.13, -0.2)
	var world_uv := func(p: Vector3) -> Vector2:
		var q := p - Vector3(off.x, 0, off.y)
		return Vector2(cos(rot) * q.x - sin(rot) * q.z, sin(rot) * q.x + cos(rot) * q.z) / tile
	var tri := func(axis: int, sg: float) -> Callable:
		return func(p: Vector3) -> Vector2:
			var q := p - Vector3(off.x, 0, off.y)
			if axis == 0:
				return Vector2(-sg * q.z, -q.y) / tile
			if axis == 1:
				return Vector2(q.x, sg * q.z) / tile
			return Vector2(sg * q.x, -q.y) / tile
	var s := 2.0
	var floor_pts := [Vector3(-s, 0, s), Vector3(s, 0, s), Vector3(s, 0, -s), Vector3(-s, 0, -s)]
	var uv_floor := func(p: Vector3) -> Vector2:
		return Vector2(p.x + s, p.z + s) / tile
	var floor_uvs := [Vector2(0, 2 * s), Vector2(2 * s, 2 * s), Vector2(2 * s, 0), Vector2(0, 0)].map(func(v: Vector2) -> Vector2: return v / tile)
	var wall_pts := [Vector3(-s, -s, 0), Vector3(s, -s, 0), Vector3(s, s, 0), Vector3(-s, s, 0)]
	var uv_wall := func(p: Vector3) -> Vector2:
		return Vector2(p.x + s, s - p.y) / tile
	var wall_uvs := [Vector2(0, 2 * s), Vector2(2 * s, 2 * s), Vector2(2 * s, 0), Vector2(0, 0)].map(func(v: Vector2) -> Vector2: return v / tile)
	var wall_x := [Vector3(0, -s, s), Vector3(0, -s, -s), Vector3(0, s, -s), Vector3(0, s, s)]
	var wall_mz := [Vector3(s, -s, 0), Vector3(-s, -s, 0), Vector3(-s, s, 0), Vector3(s, s, 0)]
	return [
		["world floor, relief above", SDMaterials.Mapping.WORLD, floor_pts, floor_uvs, Vector3.UP, world_uv, {"height_center": 0.0, "planar_rotation_deg": 30.0, "planar_offset_m": off}],
		["world floor, relief below", SDMaterials.Mapping.WORLD, floor_pts, floor_uvs, Vector3.UP, world_uv, {"height_center": 1.0, "planar_rotation_deg": 30.0, "planar_offset_m": off}],
		["uv floor", SDMaterials.Mapping.UV, floor_pts, floor_uvs, Vector3.UP, uv_floor, {"height_center": 1.0}],
		["uv wall facing +Z", SDMaterials.Mapping.UV, wall_pts, wall_uvs, Vector3.BACK, uv_wall, {"height_center": 0.5}],
		["triplanar floor", SDMaterials.Mapping.TRIPLANAR, floor_pts, floor_uvs, Vector3.UP, tri.call(1, 1.0), {"height_center": 1.0, "planar_offset_m": off}],
		["triplanar wall facing +X", SDMaterials.Mapping.TRIPLANAR, wall_x, wall_uvs, Vector3.RIGHT, tri.call(0, 1.0), {"height_center": 1.0, "planar_offset_m": off}],
		["triplanar wall facing -Z", SDMaterials.Mapping.TRIPLANAR, wall_mz, wall_uvs, Vector3.FORWARD, tri.call(2, -1.0), {"height_center": 0.0, "planar_offset_m": off}],
	]


## Renders [param surface] with the hit-offset debug view from [param cam_dir] (unit vector from
## the surface centre to the camera) and returns the per-pixel error of the hit position against
## the CPU reference (metres), with the number of pixels compared.
func measure_pom_error(surface: Array, field: Dictionary, tex: Texture2D, amp: float, tile: float,
		cam_dir: Vector3, distance := 1.3, stride := 24) -> Dictionary:
	h.new_debug_scene()
	var params: Dictionary = {"height_m": amp, "texture_size_m": Vector2(tile, tile)}
	params.merge(surface[6], true)
	var mat := SDMaterials.create(surface[1], {"height": tex}, params, SDMaterials.Quality.POM)
	var pts: Array = surface[2]
	h.add_quad(pts[0], pts[1], pts[2], pts[3], surface[3], mat)
	var axis: Vector3 = surface[4]
	var up := Vector3.UP if absf(axis.dot(Vector3.UP)) < 0.9 else Vector3.FORWARD
	var cam := h.add_camera(cam_dir * distance, Vector3.ZERO, 60.0, up)
	debug_view(Harness.DEBUG_HIT_OFFSET)
	await h.frames(3)
	var img := await h.capture()
	var ref_surface := {"point": Vector3.ZERO, "normal": axis, "axis": axis, "uv": surface[5], "amp": amp,
			"center": float(params["height_center"]), "field": field}
	var errors := []
	for py in range(stride / 2, SIZE.y, stride):
		for px in range(stride / 2, SIZE.x, stride):
			var pos := Vector2(px + 0.5, py + 0.5)
			var o := cam.project_ray_origin(pos)
			var d := cam.project_ray_normal(pos)
			var ref := Harness.trace_height_field(o, d, ref_surface)
			if ref.is_empty():
				continue
			var raster: Vector3 = ref["raster"]
			if absf(raster.x) > 1.6 or absf(raster.y) > 1.6 or absf(raster.z) > 1.6:
				continue
			var got := Harness.decode_offset(img, Vector2i(px, py), OFFSET_SCALE)
			var want: Vector3 = ref["hit"] - raster
			errors.append((got - want).length())
	debug_view(Harness.DEBUG_OFF)
	return {"errors": errors, "image": img}


func test_pom_vs_reference() -> void:
	var tile := 1.0
	var amp := 0.05
	var field := Harness.make_stone_field(512, 70, 7)
	var tex := ImageTexture.create_from_image(field["image"])
	var views := {"steep": Vector3(0.25, 1.0, 0.35), "45 deg": Vector3(0.3, 0.75, 0.75), "grazing": Vector3(0.2, 0.42, 1.0)}
	var worst_p90 := 0.0
	for surface: Array in _surfaces(tile):
		var axis: Vector3 = surface[4]
		for view_name: String in views:
			# Views are defined for a floor (+Y up, camera towards +Z); rotate them onto the surface.
			var local: Vector3 = views[view_name].normalized()
			var basis := Basis(Quaternion(Vector3.UP, axis)) if axis != Vector3.UP else Basis.IDENTITY
			var cam_dir := (basis * local).normalized()
			var r := await measure_pom_error(surface, field, tex, amp, tile, cam_dir)
			var e: Array = r["errors"]
			var p50 := percentile(e, 0.5) * 1000.0
			var p90 := percentile(e, 0.9) * 1000.0
			worst_p90 = maxf(worst_p90, p90)
			print("  %-26s %-8s %4d px  median %.3f mm  p90 %.3f mm  max %.3f mm" % [surface[0], view_name, e.size(), p50, p90, percentile(e, 1.0) * 1000.0])
			check(e.size() >= 150, "%s, %s: enough pixels compared (%d)" % [surface[0], view_name, e.size()])
			# 0.4 mm: the full march stays near 0.13 mm; without the bisection (secant only) grazing
			# views reach 0.8-1.0 mm (mutation "no binary refinement").
			check(p50 < 0.2 and p90 < 0.4, "%s, %s: hit within 0.2 mm (median) / 0.4 mm (90 %%) of the traced height field" % [surface[0], view_name])
	print("  worst 90th percentile: %.3f mm (relief %.0f mm)" % [worst_p90, amp * 1000.0])


# --- 3. Globals and parameter defaults --------------------------------------------------------

## height_remap = (1, 0) inverts the height map: the inverted map with the inverted remap must
## march to the same hits as the original (hit-offset debug view).
func test_height_remap() -> void:
	var field := Harness.make_stone_field(256, 40, 5)
	var inverted_data := PackedFloat32Array()
	for v: float in field["data"]:
		inverted_data.append(1.0 - v)
	var inverted := Harness.field_from_data(inverted_data, 256)
	var images := []
	for pair: Array in [[field, Vector2(0.0, 1.0)], [inverted, Vector2(1.0, 0.0)]]:
		var tex := ImageTexture.create_from_image((pair[0] as Dictionary)["image"])
		var mat := SDMaterials.create(SDMaterials.Mapping.WORLD, {"height": tex},
				{"height_m": 0.05, "height_center": 0.0, "texture_size_m": Vector2(1.0, 1.0), "height_remap": pair[1]}, SDMaterials.Quality.POM)
		h.new_debug_scene()
		h.add_quad(Vector3(-2, 0, 2), Vector3(2, 0, 2), Vector3(2, 0, -2), Vector3(-2, 0, -2),
				[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)], mat)
		h.add_camera(Vector3(0.3, 0.9, 1.0), Vector3.ZERO)
		debug_view(Harness.DEBUG_HIT_OFFSET)
		await h.frames(3)
		images.append(await h.capture())
	debug_view(Harness.DEBUG_OFF)
	var errors := []
	var moved := 0
	for py in range(2, SIZE.y, 6):
		for px in range(2, SIZE.x, 6):
			var a := Harness.decode_offset(images[0], Vector2i(px, py), OFFSET_SCALE)
			var b := Harness.decode_offset(images[1], Vector2i(px, py), OFFSET_SCALE)
			if a.length() > 0.002:
				moved += 1
			errors.append((a - b).length())
	print("  %d pixels, %d with more than 2 mm of parallax; difference p99 %.3f mm, largest %.3f mm" % [errors.size(), moved, percentile(errors, 0.99) * 1000.0, percentile(errors, 1.0) * 1000.0])
	check(moved > errors.size() / 4 and percentile(errors, 0.99) < 0.0002, "an inverted map with height_remap (1, 0) draws the same relief (99 % within 0.2 mm)")


## World-planar mapping on walls: seen edge-on the planar texture has no frame on the surface;
## normal mapping must still give finite, lit pixels (no NaN, which glows and smears with TAA).
## A smoke test: normalize() of the zero vector the frame had there is undefined in GLSL, and the
## GTX 1080 happens to return a finite value, so this test cannot tell the fallback is missing.
func test_world_planar_walls() -> void:
	var base := "res://demo/textures/gravel_stones/gravel_stones"
	var textures := {"albedo": load(base + "_albedo.jpg"), "normal": load(base + "_normal.jpg"), "orm": load(base + "_arm.jpg"),
			"height": load(base + "_height.exr")}
	var bad := 0
	var lit := 0
	var total := 0
	for quality in [SDMaterials.Quality.FLAT, SDMaterials.Quality.POM_SELF_SHADOW]:
		h.new_lit_scene(Color(0.2, 0.2, 0.2))
		var mat := SDMaterials.create(SDMaterials.Mapping.WORLD, textures, {"height_m": 0.03, "height_center": 0.0}, quality)
		var box := MeshInstance3D.new()
		box.mesh = BoxMesh.new()
		box.material_override = mat
		h.scene.add_child(box)
		h.add_sun(40.0, 30.0, false)
		h.add_camera(Vector3(1.6, 0.9, 1.9), Vector3.ZERO)
		await h.frames(4)
		var img := await h.capture()
		for py in range(0, SIZE.y, 3):
			for px in range(0, SIZE.x, 3):
				var c := img.get_pixel(px, py)
				if is_nan(c.r) or is_nan(c.g) or is_nan(c.b) or is_inf(c.r) or is_inf(c.g) or is_inf(c.b):
					bad += 1
				elif Harness.luminance(c) > 0.01:
					lit += 1
				total += 1
	print("  %d pixels: %d not finite, %d lit" % [total, bad, lit])
	check(bad == 0 and lit > total / 20, "a world-planar material on a box's walls gives finite, lit pixels (flat and self-shadowing variants)")


func test_globals_and_defaults() -> void:
	SDSettings.create_preset(SDSettings.Preset.HIGH).apply_globals()
	var steps: Vector4 = SDGlobals.get_value(SDGlobals.POM_STEPS)
	var shadow: Vector4 = SDGlobals.get_value(SDGlobals.SHADOW)
	check(steps == Vector4(10, 28, 4, 0) and shadow.z > 0.0 and shadow.w == 1.0, "a preset writes its steps and soft self-shadow into the globals")
	SDSettings.create_preset(SDSettings.Preset.MEDIUM).apply_globals()
	shadow = SDGlobals.get_value(SDGlobals.SHADOW)
	check(shadow.z == 0.0 and shadow.w == 1.0, "Medium: hard self-shadow")
	# The globals' registered defaults are Medium's, so materials look right before any node runs.
	var medium_ok := true
	for name: StringName in [SDGlobals.POM_STEPS, SDGlobals.POM_RANGE, SDGlobals.SHADOW]:
		medium_ok = medium_ok and SDGlobals.definitions()[name][2] == SDGlobals.get_value(name)
		medium_ok = medium_ok and ProjectSettings.get_setting("shader_globals/" + String(name))["value"] == SDGlobals.get_value(name)
	check(medium_ok, "the registered defaults and this project's shader globals are the Medium preset")
	var shader := SDMaterials.get_shader(SDMaterials.Mapping.WORLD, SDMaterials.Quality.POM)
	var mismatches := []
	for name: String in SDMaterials.PARAMETER_DEFAULTS:
		var want: Variant = SDMaterials.PARAMETER_DEFAULTS[name]
		var got: Variant = RenderingServer.shader_get_parameter_default(shader.get_rid(), name)
		if not _same_value(got, want):
			mismatches.append("%s: shader %s, SDMaterials %s" % [name, got, want])
	for m: String in mismatches:
		print("  " + m)
	check(mismatches.is_empty(), "SDMaterials.PARAMETER_DEFAULTS equal the shader's uniform defaults (%d parameters)" % SDMaterials.PARAMETER_DEFAULTS.size())
	_reset_globals()


## Equal up to float32 rounding, for floats, vectors and colours.
static func _same_value(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == b
	var fa := _floats(a)
	var fb := _floats(b)
	if fa.size() != fb.size():
		return false
	for i in fa.size():
		if absf(fa[i] - fb[i]) > 1e-6 * maxf(1.0, absf(fb[i])):
			return false
	return true


static func _floats(v: Variant) -> PackedFloat32Array:
	match typeof(v):
		TYPE_FLOAT, TYPE_INT:
			return PackedFloat32Array([float(v)])
		TYPE_VECTOR2:
			return PackedFloat32Array([v.x, v.y])
		TYPE_VECTOR3:
			return PackedFloat32Array([v.x, v.y, v.z])
		TYPE_VECTOR4:
			return PackedFloat32Array([v.x, v.y, v.z, v.w])
		TYPE_COLOR:
			return PackedFloat32Array([v.r, v.g, v.b, v.a])
	return PackedFloat32Array()


# --- 4. No swimming while the camera moves ----------------------------------------------------

## Stone tops of the field are tracked while the camera slides: for the pixel on each top, the
## GPU hit must stay on the ray-traced hit in every frame (a wrong sign shows as a drift of
## centimetres that changes with the camera, the "swimming" of broken parallax).
func test_pom_no_swimming() -> void:
	var tile := 1.0
	var amp := 0.05
	var field := Harness.make_stone_field(512, 70, 7)
	var tex := ImageTexture.create_from_image(field["image"])
	var surface: Array = _surfaces(tile)[0] # world floor, relief above, rotated and offset
	h.new_debug_scene()
	var params: Dictionary = {"height_m": amp, "texture_size_m": Vector2(tile, tile)}
	params.merge(surface[6], true)
	var mat := SDMaterials.create(surface[1], {"height": tex}, params, SDMaterials.Quality.POM)
	var pts: Array = surface[2]
	h.add_quad(pts[0], pts[1], pts[2], pts[3], surface[3], mat)
	var ref_surface := {"point": Vector3.ZERO, "normal": Vector3.UP, "axis": Vector3.UP, "uv": surface[5], "amp": amp,
			"center": 0.0, "field": field}
	# Markers: points on stone tops (h > 0.9) near the centre.
	var markers: Array[Vector3] = []
	for j in 12:
		for i in 12:
			var p := Vector3(-0.45 + 0.08 * i, 0.0, -0.45 + 0.08 * j)
			var r := Harness.relief_at(ref_surface, p)
			if r > 0.9 * amp:
				markers.append(Vector3(p.x, r, p.z))
	var cam := h.add_camera(Vector3(0.0, 1.0, 1.0), Vector3.ZERO)
	debug_view(Harness.DEBUG_HIT_OFFSET)
	var worst := 0.0
	var samples := 0
	for f in 24:
		var from := Vector3(-0.3 + 0.025 * f, 0.9 + 0.01 * f, 1.0 - 0.01 * f)
		cam.look_at_from_position(from, Vector3.ZERO)
		await h.frames(2)
		var img := await h.capture()
		for m in markers:
			if not cam.is_position_in_frustum(m):
				continue
			var pix := cam.unproject_position(m)
			var px := Vector2i(int(pix.x), int(pix.y))
			var o := cam.project_ray_origin(Vector2(px) + Vector2(0.5, 0.5))
			var d := cam.project_ray_normal(Vector2(px) + Vector2(0.5, 0.5))
			var ref := Harness.trace_height_field(o, d, ref_surface)
			if ref.is_empty() or (ref["hit"] as Vector3).distance_to(m) > 0.01:
				continue # the top is hidden from this pixel
			var got: Vector3 = (ref["raster"] as Vector3) + Harness.decode_offset(img, px, OFFSET_SCALE)
			worst = maxf(worst, got.distance_to(ref["hit"]))
			samples += 1
	debug_view(Harness.DEBUG_OFF)
	print("  %d marker samples over 24 camera positions, largest hit error %.3f mm" % [samples, worst * 1000.0])
	check(samples > 100, "stone tops stay visible along the camera path")
	check(worst < 0.0005, "the relief stays put: every tracked stone top within 0.5 mm of its traced position")


# --- 5. Triplanar marches only the planes that matter ------------------------------------------

func test_triplanar_planes() -> void:
	h.new_debug_scene()
	var field := Harness.make_wave_field(128)
	var tex := ImageTexture.create_from_image(field["image"])
	var mat := SDMaterials.create(SDMaterials.Mapping.TRIPLANAR, {"height": tex}, {"height_m": 0.03, "height_center": 1.0}, SDMaterials.Quality.POM)
	var s := 1.5
	h.add_quad(Vector3(-s, 0, s), Vector3(0, 0, s), Vector3(0, 0, -s), Vector3(-s, 0, -s),
			[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)], mat)
	# A roof at 45 degrees (normal (0.71, 0.71, 0)): two planes of equal weight.
	h.add_quad(Vector3(0, 0, s), Vector3(s, s, s), Vector3(s, s, -s), Vector3(0, 0, -s),
			[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)], mat)
	var cam := h.add_camera(Vector3(0.0, 2.5, 2.8), Vector3(0.0, 0.3, 0.0))
	debug_view(Harness.DEBUG_COST)
	await h.frames(3)
	var img := await h.capture()
	var floor_planes := {}
	var roof_planes := {}
	for py in range(10, SIZE.y, 12):
		for px in range(10, SIZE.x, 12):
			var o := cam.project_ray_origin(Vector2(px, py) + Vector2(0.5, 0.5))
			var d := cam.project_ray_normal(Vector2(px, py) + Vector2(0.5, 0.5))
			var planes := roundi(img.get_pixel(px, py).g * 3.0)
			var t_floor := -o.y / d.y if d.y < 0.0 else INF
			var hit := o + d * t_floor
			if t_floor < INF and hit.x > -s + 0.1 and hit.x < -0.1 and absf(hit.z) < s - 0.1:
				floor_planes[planes] = floor_planes.get(planes, 0) + 1
				continue
			# Roof plane: x - y = 0.
			var denom := d.x - d.y
			if absf(denom) > 1e-4:
				var t := -(o.x - o.y) / denom
				var rh := o + d * t
				if t > 0.0 and rh.x > 0.1 and rh.x < s - 0.1 and absf(rh.z) < s - 0.1:
					roof_planes[planes] = roof_planes.get(planes, 0) + 1
	debug_view(Harness.DEBUG_OFF)
	print("  planes marched per pixel: floor %s, 45-degree roof %s" % [floor_planes, roof_planes])
	check(floor_planes.keys() == [1], "a floor marches exactly one plane (the zero-weight X and Z planes are skipped)")
	check(roof_planes.keys() == [2], "a 45-degree roof marches exactly two")


# --- 6. light() reproduces Godot's shading -----------------------------------------------------

## The POM variant uses Godot's built-in lighting, the POM + self-shadow variant the addon's
## light(); with the self-shadow switched off (strength 0) they must agree per pixel, under a
## directional, an omni and a spot light (and an area light where the engine has them), for a
## dielectric and a metal. The flat variant must also agree with an ORMMaterial3D using the same
## textures, which checks the texture and normal-map path.
func test_brdf_parity() -> void:
	var base := "res://demo/textures/gravel_stones/gravel_stones"
	var textures := {"albedo": load(base + "_albedo.jpg"), "normal": load(base + "_normal.jpg"), "orm": load(base + "_arm.jpg"),
			"height": load(base + "_height.exr")}
	SDGlobals.set_value(SDGlobals.SHADOW, Vector4(8, 20, 0, 0))
	# The grazing metal case reads the energy-compensation table where it varies most (low n.v,
	# roughness 0.2-0.45); it caught a table integrated without the engine's sample rotation.
	var steep := Vector3(0.3, 1.4, 2.0)
	var grazing := Vector3(0.3, 0.22, 2.2)
	var cases := [["dielectric", {"height_m": 0.0}, steep], ["metal", {"height_m": 0.0, "metallic_scale": 1.0, "roughness_scale": 0.45}, steep],
			["metal, grazing view", {"height_m": 0.0, "metallic_scale": 1.0, "roughness_scale": 0.35}, grazing]]
	for case: Array in cases:
		var images := []
		for quality in [SDMaterials.Quality.POM, SDMaterials.Quality.POM_SELF_SHADOW]:
			images.append(await _render_lit_plane(SDMaterials.create(SDMaterials.Mapping.UV, textures, case[1], quality), true, case[2]))
		var diff := _relative_difference(images[0], images[1])
		print("  %s: light() vs built-in: mean %.3f %%, p99 %.3f %%, max %.3f %% (%d px)" % [case[0], diff["mean"] * 100.0, diff["p99"] * 100.0, diff["max"] * 100.0, diff["count"]])
		# What remains is float rounding and the soft-light size term that light() cannot see
		# (measured: 99th percentile at most 0.07 %, maximum 0.17 %). The table integrated without
		# the engine's sample rotation gave 0.20 % / 0.37 % in the grazing metal case.
		var limits: Array = [0.0012, 0.003]
		check(diff["count"] > 20000 and diff["p99"] < limits[0] and diff["max"] < limits[1], "%s: within %.2f %% (99th percentile) and %.1f %% (max) of Godot's own lighting" % [case[0], limits[0] * 100.0, limits[1] * 100.0])
	var orm := ORMMaterial3D.new()
	orm.albedo_texture = textures["albedo"]
	orm.normal_enabled = true
	orm.normal_texture = textures["normal"]
	orm.orm_texture = textures["orm"]
	orm.ao_enabled = true
	# The addon's samplers are anisotropic (BaseMaterial3D defaults to trilinear).
	orm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var standard := await _render_lit_plane(orm, false)
	# ORMMaterial3D takes metallic straight from the texture's blue channel (no scale).
	var flat := await _render_lit_plane(SDMaterials.create(SDMaterials.Mapping.UV, textures, {"metallic_scale": 1.0}, SDMaterials.Quality.FLAT), false)
	var d2 := _relative_difference(standard, flat)
	print("  flat variant vs ORMMaterial3D: p99 %.3f %%, max %.3f %%" % [d2["p99"] * 100.0, d2["max"] * 100.0])
	check(d2["max"] < 0.001, "the flat variant samples and normal-maps exactly like ORMMaterial3D")


func _render_lit_plane(material: Material, all_lights: bool, camera_position := Vector3(0.3, 1.4, 2.0)) -> Image:
	h.new_lit_scene(Color(0.15, 0.17, 0.2))
	var s := 2.0
	h.add_quad(Vector3(-s, 0, s), Vector3(s, 0, s), Vector3(s, 0, -s), Vector3(-s, 0, -s),
			[Vector2(0, 2), Vector2(2, 2), Vector2(2, 0), Vector2(0, 0)], material)
	var sun := h.add_sun(35.0, 30.0, true, 10.0)
	sun.light_energy = 1.2
	if all_lights:
		var omni := OmniLight3D.new()
		omni.position = Vector3(-0.8, 0.6, 0.4)
		omni.omni_range = 3.0
		omni.light_energy = 2.0
		omni.light_color = Color(1.0, 0.7, 0.5)
		omni.shadow_enabled = true
		h.scene.add_child(omni)
		var spot := SpotLight3D.new()
		spot.position = Vector3(0.9, 1.2, -0.3)
		spot.rotation_degrees = Vector3(-75, 20, 0)
		spot.spot_range = 3.0
		spot.light_energy = 3.0
		spot.light_color = Color(0.5, 0.7, 1.0)
		h.scene.add_child(spot)
		if ClassDB.class_exists(&"AreaLight3D"):
			var area: Light3D = ClassDB.instantiate(&"AreaLight3D")
			area.position = Vector3(0.0, 0.8, 1.0)
			area.rotation_degrees = Vector3(-60, 0, 0)
			area.light_energy = 1.5
			h.scene.add_child(area)
	h.add_camera(camera_position, Vector3(0.0, 0.0, -0.2))
	await h.frames(4)
	return await h.capture()


## Per-pixel |a - b| / max(lum(a), 0.02) over pixels that are not background.
func _relative_difference(a: Image, b: Image) -> Dictionary:
	var values := []
	for py in range(0, SIZE.y, 2):
		for px in range(0, SIZE.x, 2):
			var ca := a.get_pixel(px, py)
			var cb := b.get_pixel(px, py)
			var la := Harness.luminance(ca)
			if la <= 1e-4 and Harness.luminance(cb) <= 1e-4:
				continue
			var d := maxf(maxf(absf(ca.r - cb.r), absf(ca.g - cb.g)), absf(ca.b - cb.b))
			values.append(d / maxf(la, 0.02))
	var mean := 0.0
	for v: float in values:
		mean += v
	return {"count": values.size(), "mean": mean / maxf(values.size(), 1.0), "p99": percentile(values, 0.99), "max": percentile(values, 1.0)}


# --- 7. LIGHT_VERTEX: shadows land on the relief ------------------------------------------------

## Plateaus 8 cm above the floor (relief above) and a thin bar in the sun: on the plateau tops
## the bar's shadow must be where the analytic shadow on the plateau (not on the floor) is.
func test_light_vertex() -> void:
	var amp := 0.08
	var data := PackedFloat32Array()
	var size := 256
	data.resize(size * size)
	for y in size:
		for x in size:
			# Plateau strips 0.4 m wide every 1 m along x, with 2-texel ramps.
			var u := fposmod((x + 0.5) / size, 1.0)
			data[y * size + x] = clampf((0.35 - absf(u - 0.5)) / 0.008 + 0.5, 0.0, 1.0) if absf(u - 0.5) < 0.36 else 0.0
	var field := Harness.field_from_data(data, size)
	var tex := ImageTexture.create_from_image(field["image"])
	var mat := SDMaterials.create(SDMaterials.Mapping.WORLD, {"height": tex}, {"height_m": amp, "height_center": 0.0, "texture_size_m": Vector2(1, 1)}, SDMaterials.Quality.POM)
	h.new_lit_scene(Color(0.05, 0.05, 0.05))
	var s := 3.0
	h.add_quad(Vector3(-s, 0, s), Vector3(s, 0, s), Vector3(s, 0, -s), Vector3(-s, 0, -s),
			[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)], mat)
	var sun := h.add_sun(40.0, 0.0, true, 6.0)
	sun.shadow_bias = 0.02
	sun.shadow_normal_bias = 0.5
	var bar := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(4.0, 0.02, 0.12)
	bar.mesh = box
	bar.position = Vector3(0.0, 0.5, -0.4)
	h.scene.add_child(bar)
	var cam := h.add_camera(Vector3(0.2, 2.2, 0.8), Vector3(0.0, 0.0, 0.0))
	await h.frames(4)
	var img := await h.capture()
	var to_sun := Harness.light_direction(sun)
	var surface := {"point": Vector3.ZERO, "normal": Vector3.UP, "axis": Vector3.UP, "amp": amp, "center": 0.0, "field": field,
			"uv": func(p: Vector3) -> Vector2: return Vector2(p.x, p.z)}
	# Pixels on plateau tops whose shadow state differs between "computed at the relief" and
	# "computed on the flat surface": only those tell the two apart.
	var agree := 0
	var total := 0
	for py in range(0, SIZE.y, 2):
		for px in range(0, SIZE.x, 2):
			var o := cam.project_ray_origin(Vector2(px, py) + Vector2(0.5, 0.5))
			var d := cam.project_ray_normal(Vector2(px, py) + Vector2(0.5, 0.5))
			var ref := Harness.trace_height_field(o, d, surface)
			if ref.is_empty():
				continue
			var hit: Vector3 = ref["hit"]
			if hit.y < amp * 0.99 or absf(hit.x) > 2.0 or absf(hit.z) > 2.0:
				continue # only plateau tops
			var on_top := _bar_shadow_distance(hit, to_sun, bar.position, box.size)
			var on_floor := _bar_shadow_distance(Vector3(hit.x, 0.0, hit.z), to_sun, bar.position, box.size)
			if absf(on_top) < 0.02 or absf(on_floor) < 0.02 or (on_top > 0.0) == (on_floor > 0.0):
				continue # penumbra of the shadow map filter, or not discriminating
			var lit := Harness.luminance(img.get_pixel(px, py)) > 0.15
			total += 1
			if lit == (on_top > 0.0):
				agree += 1
	var share := float(agree) / maxf(total, 1.0)
	print("  plateau-top pixels whose shadow depends on where it is computed: %d; lit/shadowed as on the relief: %.1f %%" % [total, share * 100.0])
	check(total > 300, "the test sees enough pixels where relief and flat-surface shadows differ")
	check(share > 0.9, "the bar's shadow lands on the relief, not on the flat surface below it")


## Signed distance (m, along the sun ray's footprint) from point q to the edge of the bar's
## shadow: negative inside the shadow, positive in light.
static func _bar_shadow_distance(q: Vector3, to_sun: Vector3, centre: Vector3, size: Vector3) -> float:
	# Where the ray towards the sun crosses the bar's height, and how far that is from the bar's
	# z-extent (the bar is long in x).
	var t := (centre.y - q.y) / to_sun.y
	var z := q.z + to_sun.z * t
	return absf(z - centre.z) - size.z * 0.5


# --- 8. Self-shadowing against a traced height-field shadow -------------------------------------

func test_self_shadow() -> void:
	var tile := 1.0
	var amp := 0.05
	var field := Harness.make_stone_field(512, 70, 11)
	var tex := ImageTexture.create_from_image(field["image"])
	var mat := SDMaterials.create(SDMaterials.Mapping.WORLD, {"height": tex}, {"height_m": amp, "height_center": 0.0, "texture_size_m": Vector2(tile, tile)}, SDMaterials.Quality.POM_SELF_SHADOW)
	h.new_debug_scene()
	var s := 2.0
	h.add_quad(Vector3(-s, 0, s), Vector3(s, 0, s), Vector3(s, 0, -s), Vector3(-s, 0, -s),
			[Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)], mat)
	var sun := h.add_sun(25.0, 60.0, false)
	sun.light_energy = 1.0
	var cam := h.add_camera(Vector3(0.1, 1.3, 0.6), Vector3(0.0, 0.0, 0.0))
	SDGlobals.set_value(SDGlobals.SHADOW, Vector4(16, 20, 0, 1))
	debug_view(Harness.DEBUG_SELF_SHADOW)
	await h.frames(3)
	var img := await h.capture()
	var surface := {"point": Vector3.ZERO, "normal": Vector3.UP, "axis": Vector3.UP, "amp": amp, "center": 0.0, "field": field,
			"uv": func(p: Vector3) -> Vector2: return Vector2(p.x, p.z) / tile}
	var to_sun := Harness.light_direction(sun)
	var agree := 0
	var total := 0
	var shadowed := 0
	for py in range(4, SIZE.y, 10):
		for px in range(4, SIZE.x, 10):
			var o := cam.project_ray_origin(Vector2(px, py) + Vector2(0.5, 0.5))
			var d := cam.project_ray_normal(Vector2(px, py) + Vector2(0.5, 0.5))
			var ref := Harness.trace_height_field(o, d, surface)
			if ref.is_empty():
				continue
			var hit: Vector3 = ref["hit"]
			if absf(hit.x) > 1.5 or absf(hit.z) > 1.5:
				continue
			var want := Harness.height_field_shadowed(hit, to_sun, surface, 0.01 * amp)
			var got := img.get_pixel(px, py).r < 0.5
			total += 1
			shadowed += 1 if want else 0
			agree += 1 if want == got else 0
	var share := float(agree) / maxf(total, 1.0)
	print("  %d pixels, %.1f %% in traced shadow, classification agrees on %.1f %%" % [total, 100.0 * shadowed / maxf(total, 1.0), share * 100.0])
	check(shadowed > total / 10, "the sun is low enough to cast relief shadows")
	check(share > 0.98, "hard self-shadow agrees with a traced height-field shadow on more than 98 % of pixels")
	SDGlobals.set_value(SDGlobals.SHADOW, Vector4(16, 20, 0, 0))
	await h.frames(2)
	var off := await h.capture()
	var min_off := 1.0
	var on_quad := 0
	for py in range(4, SIZE.y, 10):
		for px in range(4, SIZE.x, 10):
			# Pixels whose ray meets the quad well inside its edges: next to the edge, Mesa's lavapipe
			# leaves a few millionths in a background pixel.
			var o := cam.project_ray_origin(Vector2(px, py) + Vector2(0.5, 0.5))
			var d := cam.project_ray_normal(Vector2(px, py) + Vector2(0.5, 0.5))
			var p := o + d * (-o.y / d.y) if d.y < 0.0 else Vector3.INF
			if absf(p.x) > 1.9 or absf(p.z) > 1.9:
				continue
			on_quad += 1
			min_off = minf(min_off, off.get_pixel(px, py).r)
	check(on_quad > 3000 and min_off > 0.999, "strength 0 switches it off (factor 1 everywhere)")
	debug_view(Harness.DEBUG_OFF)


# --- 9. Opt-in depth write ----------------------------------------------------------------------

## A red box pushed 3 cm into a wall with 4 cm of recessed relief. With the depth write the box
## shows exactly where it is in front of the traced relief; without it, where it is in front of
## the flat wall plane. In both cases the wall itself has no holes.
func test_depth_write() -> void:
	var tile := 1.0
	var amp := 0.04
	var field := Harness.make_stone_field(512, 70, 5)
	var tex := ImageTexture.create_from_image(field["image"])
	var s := 1.5
	var surface := {"point": Vector3.ZERO, "normal": Vector3.BACK, "axis": Vector3.BACK, "amp": amp, "center": 1.0, "field": field,
			"uv": func(p: Vector3) -> Vector2: return Vector2(p.x + s, s - p.y) / tile}
	var box_min := Vector3(-0.3, -0.25, -0.03)
	var box_max := Vector3(0.3, 0.25, 0.3)
	var views := [Vector3(0.9, 0.5, 0.9), Vector3(-0.7, -0.4, 1.1), Vector3(0.2, 0.9, 0.8), Vector3(-1.0, 0.2, 0.5)]
	for depth in [true, false]:
		h.new_debug_scene()
		var mat := SDMaterials.create(SDMaterials.Mapping.UV, {"height": tex}, {"height_m": amp, "height_center": 1.0}, SDMaterials.Quality.POM, depth)
		h.add_quad(Vector3(-s, -s, 0), Vector3(s, -s, 0), Vector3(s, s, 0), Vector3(-s, s, 0),
				[Vector2(0, 2 * s), Vector2(2 * s, 2 * s), Vector2(2 * s, 0), Vector2(0, 0)].map(func(v: Vector2) -> Vector2: return v / tile), mat)
		var red := StandardMaterial3D.new()
		red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		red.albedo_color = Color(1, 0, 0)
		var box := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = box_max - box_min
		box.mesh = bm
		box.material_override = red
		box.position = (box_min + box_max) * 0.5
		h.scene.add_child(box)
		# Normals view: the wall is never black (0.5 + n / 2), so black means a hole.
		debug_view(Harness.DEBUG_NORMAL)
		var cam := h.add_camera(views[0], Vector3.ZERO)
		var agree := 0
		var total := 0
		var holes := 0
		var wall_px := 0
		for view: Vector3 in views:
			cam.look_at_from_position(view, Vector3.ZERO)
			await h.frames(20)
			var img := await h.capture()
			for py in range(0, SIZE.y, 2):
				for px in range(0, SIZE.x, 2):
					var o := cam.project_ray_origin(Vector2(px, py) + Vector2(0.5, 0.5))
					var d := cam.project_ray_normal(Vector2(px, py) + Vector2(0.5, 0.5))
					var t_plane := -o.z / d.z
					var on_wall := t_plane > 0.0 and absf((o + d * t_plane).x) < s - 0.05 and absf((o + d * t_plane).y) < s - 0.05
					var t_box := _ray_box(o, d, box_min, box_max)
					var c := img.get_pixel(px, py)
					if on_wall and t_box == INF:
						wall_px += 1
						if c.r + c.g + c.b <= 0.0:
							holes += 1
					if t_box == INF or not on_wall:
						continue
					# Only pixels where the relief and the flat plane disagree about the box tell a
					# depth write from none.
					var ref := Harness.trace_height_field(o, d, surface)
					var relief_t := (ref["hit"] as Vector3).distance_to(o) if not ref.is_empty() else t_plane
					if (t_box < relief_t) == (t_box < t_plane) or absf(t_box - relief_t) < 0.004 or absf(t_box - t_plane) < 0.004:
						continue
					var is_red := c.r > 0.9 and c.g < 0.1 and c.b < 0.1
					total += 1
					agree += 1 if is_red == (t_box < (relief_t if depth else t_plane)) else 0
		var share := float(agree) / maxf(total, 1.0)
		var label := "depth write" if depth else "no depth write"
		print("  %s: %d pixels where relief and plane disagree about the box, box as predicted by the %s on %.1f %%; %d of %d wall pixels empty (4 views)" % [
				label, total, "relief" if depth else "flat plane", share * 100.0, holes, wall_px])
		check(total > 500 and share > 0.95, "%s: the box is hidden exactly where the %s is in front of it" % [label, "traced relief" if depth else "flat wall plane"])
		# Without the rounding in sd_surface.gdshaderinc about 1.3 % of the depth-writing wall's
		# pixels drop out (pre-pass and colour pass disagree in the last bit); with it, at most a
		# few per million may.
		var limit := 0.00002 if depth else 0.0
		check(float(holes) / wall_px <= limit, "%s: the wall has no holes (at most %.0f per million pixels where pre-pass and colour pass disagree on its depth)" % [label, limit * 1e6])
	debug_view(Harness.DEBUG_OFF)


## Entry distance of the ray into the box, or INF.
static func _ray_box(o: Vector3, d: Vector3, lo: Vector3, hi: Vector3) -> float:
	var t0 := -INF
	var t1 := INF
	for i in 3:
		if absf(d[i]) < 1e-9:
			if o[i] < lo[i] or o[i] > hi[i]:
				return INF
			continue
		var a := (lo[i] - o[i]) / d[i]
		var b := (hi[i] - o[i]) / d[i]
		t0 = maxf(t0, minf(a, b))
		t1 = minf(t1, maxf(a, b))
	return t0 if t0 <= t1 and t1 > 0.0 else INF


# --- 10. No mip shimmer at a distance -------------------------------------------------------------

## The camera creeps sideways by a fraction of a pixel per frame over gravel 10-60 m away; the
## per-pixel flicker of the POM surface must stay close to that of the same material without
## POM (which only has the hardware's mip filtering). Sampling the heights without mipmaps shows
## as flicker several times higher.
func test_mip_shimmer() -> void:
	var results := {}
	for quality in [SDMaterials.Quality.FLAT, SDMaterials.Quality.POM]:
		h.new_lit_scene(Color(0.2, 0.2, 0.22))
		var mat := SDMaterials.from_texture_set("res://demo/textures/clean_pebbles", SDMaterials.Mapping.WORLD, {"height_center": 0.0, "height_m": 0.04}, quality)
		var plane := PlaneMesh.new()
		plane.size = Vector2(200, 200)
		var mi := MeshInstance3D.new()
		mi.mesh = plane
		mi.material_override = mat
		h.scene.add_child(mi)
		var sun := h.add_sun(30.0, 40.0, false)
		sun.light_energy = 1.5
		var cam := h.add_camera(Vector3(0, 1.7, 0), Vector3(0, 0.3, -30))
		SDGlobals.set_value(SDGlobals.POM_RANGE, Vector4(1000, 2000, 0, 99))
		var frames: Array[Image] = []
		for f in 16:
			cam.look_at_from_position(Vector3(0.0013 * f, 1.7, 0.0), Vector3(0.0013 * f, 0.3, -30.0))
			await h.frames(2)
			frames.append(await h.capture())
		results[quality] = _flicker(frames, cam)
	var ratio: float = results[SDMaterials.Quality.POM] / maxf(results[SDMaterials.Quality.FLAT], 1e-6)
	print("  mean per-pixel flicker 10-60 m away: flat %.5f, POM %.5f (x%.2f)" % [results[SDMaterials.Quality.FLAT], results[SDMaterials.Quality.POM], ratio])
	# Measured: x1.02 with mip-correct sampling, x1.8 when the march reads mip 0 (mutation check).
	check(ratio < 1.3, "POM adds less than 30 % flicker over plain normal mapping at a distance")


# --- 11. Distance fade ---------------------------------------------------------------------------

## With the fade set to 6-10 m, the parallax offset must be the full one before 6 m, shrink in
## between and be exactly zero beyond 10 m (plain normal mapping, no march).
func test_distance_fade() -> void:
	var field := Harness.make_stone_field(256, 40, 2)
	var tex := ImageTexture.create_from_image(field["image"])
	h.new_debug_scene()
	var mat := SDMaterials.create(SDMaterials.Mapping.WORLD, {"height": tex}, {"height_m": 0.05, "height_center": 0.0, "texture_size_m": Vector2(1, 1)}, SDMaterials.Quality.POM)
	var plane := PlaneMesh.new()
	plane.size = Vector2(60, 60)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	mi.material_override = mat
	h.scene.add_child(mi)
	var cam := h.add_camera(Vector3(0, 1.7, 0), Vector3(0, 0, -8))
	SDGlobals.set_value(SDGlobals.POM_RANGE, Vector4(6, 10, 0, 99))
	debug_view(Harness.DEBUG_HIT_OFFSET)
	await h.frames(3)
	var img := await h.capture()
	var near_max := 0.0
	var far_max := 0.0
	var far_n := 0
	for py in range(0, SIZE.y, 2):
		for px in range(0, SIZE.x, 4):
			var o := cam.project_ray_origin(Vector2(px, py) + Vector2(0.5, 0.5))
			var d := cam.project_ray_normal(Vector2(px, py) + Vector2(0.5, 0.5))
			if d.y >= 0.0:
				continue
			var dist := (o + d * (-o.y / d.y)).distance_to(o)
			var off := Harness.decode_offset(img, Vector2i(px, py), OFFSET_SCALE).length()
			if dist < 5.0:
				near_max = maxf(near_max, off)
			elif dist > 10.5 and dist < 28.0:
				far_max = maxf(far_max, off)
				far_n += 1
	debug_view(Harness.DEBUG_OFF)
	print("  largest parallax offset: before the fade %.1f mm, beyond it %.3f mm (%d px)" % [near_max * 1000.0, far_max * 1000.0, far_n])
	check(near_max > 0.02, "the full relief is there before the fade starts")
	check(far_n > 1000 and far_max < 0.0002, "beyond the fade end the offset is zero (plain normal mapping)")


## Mean over pixels (ground 10-60 m away) of the standard deviation of luminance over frames.
func _flicker(frames: Array[Image], cam: Camera3D) -> float:
	var total := 0.0
	var n := 0
	for py in range(0, SIZE.y, 2):
		var o := cam.project_ray_origin(Vector2(SIZE.x * 0.5, py))
		var d := cam.project_ray_normal(Vector2(SIZE.x * 0.5, py))
		if d.y >= 0.0:
			continue
		var dist := -o.y / d.y
		if dist < 10.0 or dist > 60.0:
			continue
		for px in range(SIZE.x / 4, 3 * SIZE.x / 4, 2):
			var sum := 0.0
			var sum2 := 0.0
			for img in frames:
				var l := Harness.luminance(img.get_pixel(px, py))
				sum += l
				sum2 += l * l
			var mean := sum / frames.size()
			total += sqrt(maxf(sum2 / frames.size() - mean * mean, 0.0))
			n += 1
	return total / maxf(n, 1.0)
