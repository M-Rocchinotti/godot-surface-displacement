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
	await _test("pom_matches_ray_traced_height_field", test_pom_vs_reference)
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
			check(p50 < 0.25 and p90 < 1.0, "%s, %s: hit within 0.25 mm (median) / 1 mm (90 %%) of the traced height field" % [surface[0], view_name])
	print("  worst 90th percentile: %.3f mm (relief %.0f mm)" % [worst_p90, amp * 1000.0])
