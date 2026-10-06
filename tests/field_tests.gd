extends SceneTree
## Headed render tests of the near-camera geometry (GADSDisplacementField3D), the ground bake, the
## pebble scatter, node lifetime and the demo scenes:
##     python tools/godot.py --script tests/field_tests.gd
## Exit code 0 = all passed. Run a subset with: -- --only=name,name

const Harness := preload("res://tests/lib/gads_harness.gd")
const Builder := preload("res://demo/scenes/demo_builder.gd")
const SIZE := Vector2i(960, 540)
const S0 := 0.02
const N := 128
const LEVELS := 4

var h: Harness
var _passed := 0
var _failed := 0


func _initialize() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	GADSGlobals.ensure_registered()
	h = Harness.new(self)
	h.make_viewport(SIZE, true)
	_run()


func _run() -> void:
	await _test("vertex_heights_match_the_height_map", test_vertex_heights)
	await _test("runtime_deformation_moves_the_geometry", test_deformation)
	await _test("baked_ground_matches_the_cpu_reference", test_baked_ground)
	await _test("field_pom_matches_ray_traced_height_field", test_field_pom)
	await _test("no_cracks_between_rings", test_no_cracks)
	await _test("geometry_does_not_swim", test_no_swimming)
	await _test("edge_blends_into_pom", test_edge_seam)
	await _test("edge_blends_into_pom_in_weather", test_edge_seam_weather)
	await _test("surface_queries", test_surface_queries)
	await _test("ground_bake_precision", test_ground_bake)
	await _test("pebbles_stay_put", test_pebbles)
	await _test("lifetime_resize_viewports", test_lifetime)
	await _test("demo_scenes_render", test_demo_scenes)
	await _test("demo_camera_flies", test_demo_camera)
	print("\nfield tests: %d passed, %d failed" % [_passed, _failed])
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
	GADSSettings.create_preset(GADSSettings.Preset.HIGH).apply_globals()
	# No distance fade of the parallax relief (it would also scale the geometry).
	GADSGlobals.set_value(GADSGlobals.POM_RANGE, Vector4(1000, 2000, 0, 99))
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(0, 0.1, 0, 0))
	await fn.call()


func check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("  ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL %s" % what)


## A field over flat ground at y = 0 with one layer (world-planar, relief above) using
## [param field] as height map, tile [param tile] m, relief [param amp] m, following
## [param tracked]. Returns the field.
func add_field(field: Dictionary, tile: float, amp: float, tracked: Camera3D, quality := GADSMaterials.Quality.FLAT) -> GADSDisplacementField3D:
	var tex := ImageTexture.create_from_image(field["image"])
	var layer := GADSMaterials.create(GADSMaterials.Mapping.WORLD, {"height": tex},
			{"height_m": amp, "height_center": 0.0, "texture_size_m": Vector2(tile, tile)}, GADSMaterials.Quality.POM)
	var f := GADSDisplacementField3D.new()
	f.levels = LEVELS
	f.resolution = N
	f.base_spacing = S0
	f.layers = [layer]
	f.camera = tracked
	f.bake_on_ready = false
	h.scene.add_child(f)
	f.set_quality(quality)
	return f


## An orthographic camera looking straight down over [param centre] with pixels of
## [param pixel_m], so pixel (i, j) sees world (centre.x + (i + 0.5 - w/2) * pixel_m, centre.z + ...).
func add_top_camera(centre: Vector2, pixel_m: float) -> Camera3D:
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.size = SIZE.y * pixel_m
	cam.near = 0.1
	cam.far = 50.0
	h.scene.add_child(cam)
	cam.global_transform = Transform3D(Basis(Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(0, 1, 0)), Vector3(centre.x, 20.0, centre.y))
	cam.current = true
	return cam


static func pixel_to_xz(px: Vector2i, centre: Vector2, pixel_m: float) -> Vector2:
	return centre + (Vector2(px) + Vector2(0.5, 0.5) - Vector2(SIZE) * 0.5) * pixel_m


## A second camera that the field follows (not rendered).
func add_tracked_camera(pos: Vector3) -> Camera3D:
	var cam := Camera3D.new()
	cam.position = pos
	h.scene.add_child(cam)
	return cam


# --- 1. Vertex heights ------------------------------------------------------------------------

## Top-down orthographic view with one pixel per innermost vertex, pixel centres on the lattice:
## every pixel on a vertex of its ring (away from morph bands) must show exactly
## lift + relief(height map at the ring's mip), computed here from the height image itself.
func test_vertex_heights() -> void:
	var tile := 1.28 # 256 px -> 5 mm texels; S0 = 2 cm -> ring k samples mip 2 + k
	var amp := 0.04
	var field := Harness.make_wave_field(256)
	h.new_debug_scene()
	var tracked := add_tracked_camera(Vector3(0.37, 1.7, -0.23))
	var f := add_field(field, tile, amp, tracked)
	await h.frames(3)
	# The test's own snapping formula (not the node's).
	var snap := pow(2.0, LEVELS) * S0
	var origin := Vector2(floorf(0.37 / snap + 0.5) * snap, floorf(-0.23 / snap + 0.5) * snap)
	var centre := origin - Vector2(0.5, 0.5) * S0
	add_top_camera(centre, S0)
	var scale := 0.05
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(Harness.DEBUG_WORLD_HEIGHT, scale, 0.0, 0.0))
	await h.frames(5)
	var img := await h.capture()
	var mips := []
	for k in LEVELS:
		mips.append(Harness.field_mip(field, 2 + k))
	var fade := f.get_fade_range()
	var errors := []
	var per_ring := [0, 0, 0, 0]
	for py in range(0, SIZE.y, 3):
		for px in range(0, SIZE.x, 3):
			var xz := pixel_to_xz(Vector2i(px, py), centre, S0)
			var lat := ((xz - origin) / S0).round()
			var ring := maxf(absf(lat.x), absf(lat.y))
			var k := 0
			while k < LEVELS - 1 and ring > N / 2.0 * pow(2.0, k):
				k += 1
			var step := pow(2.0, k)
			if fposmod(lat.x, step) != 0.0 or fposmod(lat.y, step) != 0.0:
				continue # not a vertex of its ring
			if is_equal_approx(ring, N / 2.0 * step) or (k > 0 and is_equal_approx(ring, N / 4.0 * step)):
				continue # ring edges (forced morph)
			var d := xz.distance_to(Vector2(tracked.position.x, tracked.position.z))
			if d >= f.get_morph_range(k).x or d >= fade.x:
				continue # morphing or fading
			var hm: float = Harness.sample_field(mips[k], xz / tile)
			var want := f.lift + amp * hm
			var got := img.get_pixel(px, py).r * scale
			errors.append(absf(got - want))
			per_ring[k] += 1
	var worst := percentile(errors, 1.0)
	print("  %d vertices checked (per ring %s), largest error %.4f mm" % [errors.size(), per_ring, worst * 1000.0])
	check(per_ring[0] > 300 and per_ring[1] > 300 and per_ring[2] > 100, "vertices of the inner three rings are checked")
	check(worst < 0.00005, "every vertex is at lift + relief of the height map at its ring's mip (within 0.05 mm)")
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(0, 0.1, 0, 0))


## Runtime deformation (GADSDeformationField): marks stamped near the camera press the field's
## vertices down by the depth the field reports for scripts (get_depth(), the CPU twin of the
## shaders' gads_deformation()), unfaded; marks recover over time.
func test_deformation() -> void:
	var tile := 1.28
	var amp := 0.04
	var field := Harness.make_wave_field(256)
	h.new_debug_scene()
	var tracked := add_tracked_camera(Vector3(0.37, 1.7, -0.23))
	var f := add_field(field, tile, amp, tracked)
	var deform := GADSDeformationField.new()
	deform.size_m = 4.0
	deform.resolution = 256
	deform.max_depth = 0.2
	deform.follow = deform.get_path_to(tracked) if deform.is_inside_tree() else NodePath()
	h.scene.add_child(deform)
	deform.follow = deform.get_path_to(tracked)
	deform.stamp(Vector3(0.2, 0, -0.1), 0.25, 0.06)
	deform.stamp(Vector3(0.7, 0, -0.5), 0.15, 0.03, 0.01)
	deform.stroke(Vector3(-0.4, 0, 0.2), Vector3(0.6, 0, 0.3), 0.12, 0.05)
	await h.frames(3)
	var snap := pow(2.0, LEVELS) * S0
	var origin := Vector2(floorf(0.37 / snap + 0.5) * snap, floorf(-0.23 / snap + 0.5) * snap)
	var centre := origin - Vector2(0.5, 0.5) * S0
	add_top_camera(centre, S0)
	var scale := 0.05
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(Harness.DEBUG_WORLD_HEIGHT, scale, 0.0, 0.0))
	await h.frames(5)
	var img := await h.capture()
	var mip := Harness.field_mip(field, 2)
	var errors := []
	var pressed := 0
	for py in range(0, SIZE.y, 3):
		for px in range(0, SIZE.x, 3):
			var xz := pixel_to_xz(Vector2i(px, py), centre, S0)
			var lat := ((xz - origin) / S0).round()
			if maxf(absf(lat.x), absf(lat.y)) >= N / 2.0 - 1.0:
				continue # inner ring only: no morph
			if xz.distance_to(Vector2(tracked.position.x, tracked.position.z)) >= f.get_morph_range(0).x:
				continue
			var depth := deform.get_depth(Vector3(xz.x, 0, xz.y))
			pressed += 1 if depth > 0.001 else 0
			var want := f.lift + amp * Harness.sample_field(mip, xz / tile) - depth
			errors.append(absf(img.get_pixel(px, py).r * scale - want))
	var worst := percentile(errors, 1.0)
	print("  %d vertices, %d of them pressed down; largest error %.4f mm" % [errors.size(), pressed, worst * 1000.0])
	check(pressed > 50, "marks cover vertices")
	check(worst < 0.0001, "every vertex is at lift + relief - deformation (within 0.1 mm)")
	# Recovery: after 1 s at 2 cm/s a fresh 6 cm mark is 4 cm deep (recovery counts from each mark's
	# stamp time, so a rate set later applies to the time already passed too).
	deform.stamp(Vector3(0.2, 0, -0.1), 0.25, 0.06, 0.0, GADSDeformationField.Combine.SET)
	deform.recovery_rate = 0.02
	var before := deform.get_depth(Vector3(0.2, 0, -0.1))
	deform._process(1.0)
	var after := deform.get_depth(Vector3(0.2, 0, -0.1))
	print("  mark centre %.4f m, after 1 s of recovery %.4f m" % [before, after])
	check(absf(before - 0.06) < 0.002 and absf(after - (before - 0.02)) < 1e-4, "marks recover at recovery_rate")
	deform.queue_free()
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(0, 0.1, 0, 0))
	await h.frames(2)
	check(float((GADSGlobals.get_value(GADSGlobals.DEFORM_PARAMS) as Vector4).w) == 0.0, "a removed field turns the deformation off in the shaders")


## The field over a baked ground with a gentle slope, a 6 cm kerb, a cell without ground and
## ground that is none of the field's layers: every vertex (away from morph bands and the fade)
## must sit where GADSGroundBake.sample() - the CPU twin of gads_ground.gdshaderinc - puts it:
## mix(ground - push_down, ground + lift + relief, smoothstep(0.35, 0.65, weight sum)).
func test_baked_ground() -> void:
	var tile := 1.28
	var amp := 0.04
	var field := Harness.make_wave_field(256)
	h.new_debug_scene()
	var tracked := add_tracked_camera(Vector3(0.37, 1.7, -0.23))
	var f := add_field(field, tile, amp, tracked)
	var texel := 0.05
	var cells := Vector2i(200, 200)
	var bake_origin := Vector2(-5.0, -5.0)
	var heights := PackedFloat32Array()
	var layer_ids := PackedInt32Array()
	for y in cells.y:
		for x in cells.x:
			var p := bake_origin + (Vector2(x, y) + Vector2(0.5, 0.5)) * texel
			heights.append(0.004 * p.x - 0.003 * p.y + (0.06 if p.x > 1.5 else 0.0))
			var id := 0
			if p.y > 2.2:
				id = -1
			if p.distance_to(Vector2(-1.2, 0.9)) < 0.12:
				id = -2
			layer_ids.append(id)
	var bake := GADSGroundBake.from_arrays(cells, heights, layer_ids, bake_origin, texel)
	f.ground_bake = bake
	await h.frames(3)
	var snap := pow(2.0, LEVELS) * S0
	var origin := Vector2(floorf(0.37 / snap + 0.5) * snap, floorf(-0.23 / snap + 0.5) * snap)
	var centre := origin - Vector2(0.5, 0.5) * S0
	add_top_camera(centre, S0)
	# World height in units of 0.2 m, around 0 (the linear tone mapper keeps negative values): the
	# heights here (-0.14 to 0.14 m) read back as -0.7 to 0.7, where a half float's step is at
	# most 0.1 mm. (Relative to -0.2 m, values of 1 to 1.7 had 0.2 mm steps: a driver that
	# rounds towards zero when writing half floats, like Mesa's lavapipe, lost two of them, 0.4
	# mm, between the 3D and the 2D buffer.)
	var reference := 0.0
	var scale := 0.2
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(Harness.DEBUG_WORLD_HEIGHT, scale, reference, 0.0))
	await h.frames(5)
	var img := await h.capture()
	var mips := []
	for k in LEVELS:
		mips.append(Harness.field_mip(field, 2 + k))
	var push: float = f.get_material().get_shader_parameter("push_down")
	var fade := f.get_fade_range()
	var errors := []
	var kinds := {"displaced": 0, "dived": 0, "blended": 0}
	# Every pixel (one per innermost vertex): the partly displaceable vertices lie in bands a
	# fraction of a texel wide.
	for py in SIZE.y:
		for px in SIZE.x:
			var xz := pixel_to_xz(Vector2i(px, py), centre, S0)
			var lat := ((xz - origin) / S0).round()
			var ring := maxf(absf(lat.x), absf(lat.y))
			var k := 0
			while k < LEVELS - 1 and ring > N / 2.0 * pow(2.0, k):
				k += 1
			var step := pow(2.0, k)
			if fposmod(lat.x, step) != 0.0 or fposmod(lat.y, step) != 0.0:
				continue
			if is_equal_approx(ring, N / 2.0 * step) or (k > 0 and is_equal_approx(ring, N / 4.0 * step)):
				continue
			var d := xz.distance_to(Vector2(tracked.position.x, tracked.position.z))
			if d >= f.get_morph_range(k).x or d >= fade.x:
				continue
			var s := bake.sample(xz)
			var w: Color = s["weights"]
			var displaceable := smoothstep(0.35, 0.65, w.r)
			var ground: float = s["height"]
			var want := lerpf(ground - push, ground + f.lift + amp * Harness.sample_field(mips[k], xz / tile), displaceable)
			var got := reference + img.get_pixel(px, py).r * scale
			errors.append(absf(got - want))
			if displaceable >= 1.0:
				kinds["displaced"] += 1
			elif displaceable <= 0.0:
				kinds["dived"] += 1
			else:
				kinds["blended"] += 1
	var worst := percentile(errors, 1.0)
	print("  %d vertices checked %s, largest error %.4f mm" % [errors.size(), kinds, worst * 1000.0])
	check(kinds["displaced"] > 1000 and kinds["dived"] > 1000 and kinds["blended"] > 2, "displaced, dived and partly displaced vertices are all checked")
	check(worst < 0.0003, "every vertex is where the CPU reference of the baked ground puts it (within 0.3 mm)")
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(0, 0.1, 0, 0))


static func percentile(values: Array, q: float) -> float:
	if values.is_empty():
		return INF
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[clampi(int(q * (sorted.size() - 1) + 0.5), 0, sorted.size() - 1)]


# --- 1b. The field's fragments march the relief like the surfaces -------------------------------

## The field's own parallax (its fragments march the full relief over the whole slab along the
## view ray) against the CPU ray / height-field intersection the surface test uses: the hit
## height (debug view 6) from a steep, a 45-degree and a grazing view; then its hard
## self-shadow against the CPU height-field shadow.
func test_field_pom() -> void:
	var tile := 1.0
	var amp := 0.05
	var field := Harness.make_stone_field(512, 70, 7)
	var surface := {"point": Vector3.ZERO, "normal": Vector3.UP, "axis": Vector3.UP, "amp": amp, "center": 0.0, "field": field,
			"uv": func(p: Vector3) -> Vector2: return Vector2(p.x, p.z) / tile}
	var views := {"steep": Vector3(0.25, 1.0, 0.35), "45 deg": Vector3(0.3, 0.75, 0.75), "grazing": Vector3(0.2, 0.42, 1.0)}
	# Mip 0 forced (LOD bias -10) like the surfaces' test: the reference traces the full-size map.
	GADSGlobals.set_value(GADSGlobals.POM_RANGE, Vector4(1000, 2000, -10, 99))
	var worst := 0.0
	for view_name: String in views:
		h.new_debug_scene()
		var cam := h.add_camera((views[view_name] as Vector3).normalized() * 1.3, Vector3.ZERO, 60.0)
		var f := add_field(field, tile, amp, cam, GADSMaterials.Quality.POM)
		var reference := -0.05
		var scale := 0.1
		GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(Harness.DEBUG_WORLD_HEIGHT, scale, reference, 0.0))
		await h.frames(4)
		var img := await h.capture()
		var errors := []
		for py in range(12, SIZE.y, 24):
			for px in range(12, SIZE.x, 24):
				var o := cam.project_ray_origin(Vector2(px, py) + Vector2(0.5, 0.5))
				var d := cam.project_ray_normal(Vector2(px, py) + Vector2(0.5, 0.5))
				var ref := Harness.trace_height_field(o, d, surface)
				if ref.is_empty():
					continue
				var raster: Vector3 = ref["raster"]
				if absf(raster.x) > 1.6 or absf(raster.z) > 1.6:
					continue
				var y := reference + img.get_pixel(px, py).r * scale
				var got := o + d * ((y - o.y) / d.y)
				errors.append(got.distance_to(ref["hit"]))
		var p50 := percentile(errors, 0.5) * 1000.0
		var p90 := percentile(errors, 0.9) * 1000.0
		worst = maxf(worst, p90)
		print("  %-8s %4d px  median %.3f mm  p90 %.3f mm" % [view_name, errors.size(), p50, p90])
		check(errors.size() >= 150 and p50 < 0.2 and p90 < 0.4, "%s: the field's hit within 0.2 mm (median) / 0.4 mm (90 %%) of the traced height field" % view_name)
		f.free()
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(0, 0.1, 0, 0))

	# Hard self-shadow, as the surfaces' test does it.
	h.new_debug_scene()
	var sun := h.add_sun(25.0, 60.0, false)
	sun.light_energy = 1.0
	var cam := h.add_camera(Vector3(0.1, 1.3, 0.6), Vector3(0.0, 0.0, 0.0))
	add_field(field, tile, amp, cam, GADSMaterials.Quality.POM_SELF_SHADOW)
	GADSGlobals.set_value(GADSGlobals.SHADOW, Vector4(16, 20, 0, 1))
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(Harness.DEBUG_SELF_SHADOW, 0.1, 0.0, 0.0))
	await h.frames(4)
	var img := await h.capture()
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
			total += 1
			shadowed += 1 if want else 0
			agree += 1 if want == (img.get_pixel(px, py).r < 0.5) else 0
	var share := float(agree) / maxf(total, 1.0)
	print("  self-shadow: %d pixels, %.1f %% in traced shadow, classification agrees on %.1f %%" % [total, 100.0 * shadowed / maxf(total, 1.0), share * 100.0])
	check(shadowed > total / 10 and share > 0.98, "the field's hard self-shadow agrees with a traced height-field shadow on more than 98 % of pixels")
	GADSGlobals.set_value(GADSGlobals.SHADOW, Vector4(8, 20, 0, 1))
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(0, 0.1, 0, 0))


# --- 2. No cracks -------------------------------------------------------------------------------

## A white field (10 cm of steep relief) on black from several heights and directions: every
## pixel whose ray reaches the ground inside the grid must hit the field.
func test_no_cracks() -> void:
	var field := Harness.make_stone_field(512, 90, 3)
	h.new_debug_scene()
	var cam := h.add_camera(Vector3(0.11, 1.6, 0.07), Vector3(0.0, 0.0, -3.0))
	var f := add_field(field, 1.0, 0.1, cam)
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(Harness.DEBUG_WHITE, 0.1, 0.0, 0.0))
	var poses := [[Vector3(0.11, 1.6, 0.07), Vector3(0.0, 0.0, -3.0)], [Vector3(-0.23, 2.5, 0.31), Vector3(1.0, 0.0, -4.0)],
			[Vector3(0.52, 0.8, -0.17), Vector3(-2.0, 0.0, -2.5)], [Vector3(0.05, 4.0, 0.2), Vector3(0.3, 0.0, -1.5)],
			[Vector3(-0.41, 1.2, 0.66), Vector3(3.0, 0.0, 1.0)], [Vector3(0.29, 3.2, -0.08), Vector3(-1.0, 0.0, 5.0)]]
	var total_black := 0
	var total := 0
	for pose: Array in poses:
		cam.look_at_from_position(pose[0], pose[1])
		await h.frames(4)
		var img := await h.capture()
		var origin := f.snapped_origin(cam.global_position)
		var inner := f.get_reach() - 0.15
		var black := 0
		for py in range(0, SIZE.y, 1):
			for px in range(0, SIZE.x, 2):
				var o := cam.project_ray_origin(Vector2(px, py) + Vector2(0.5, 0.5))
				var d := cam.project_ray_normal(Vector2(px, py) + Vector2(0.5, 0.5))
				if d.y >= -0.02:
					continue
				var hit := o + d * (-o.y / d.y)
				if absf(hit.x - origin.x) > inner or absf(hit.z - origin.z) > inner:
					continue
				total += 1
				if img.get_pixel(px, py).r < 0.5:
					black += 1
		total_black += black
		print("  camera at %s: %d background pixels inside the grid" % [pose[0], black])
	check(total > 500000, "the views cover the grid (%d pixels)" % total)
	check(total_black == 0, "no background shows through anywhere in the grid (ring seams are closed)")
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(0, 0.1, 0, 0))


# --- 3. No swimming ----------------------------------------------------------------------------

## The tracked camera walks 40 cm in 1 cm steps (crossing a snap of the grid) while a top-down
## camera films the ground: near the walker (innermost ring, no morph) the height at every
## pixel must not change at all; in the innermost ring's morph band it may only change
## gradually (no jumps when the grid snaps).
func test_no_swimming() -> void:
	var field := Harness.make_stone_field(512, 90, 4)
	h.new_debug_scene()
	var tracked := add_tracked_camera(Vector3(0.0, 1.7, 0.0))
	var f := add_field(field, 1.0, 0.05, tracked)
	var pixel := 0.005
	var centre := Vector2(0.2, 0.0)
	add_top_camera(centre, pixel)
	var scale := 0.05
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(Harness.DEBUG_WORLD_HEIGHT, scale, 0.0, 0.0))
	await h.frames(4)
	var morph0 := f.get_morph_range(0)
	var still_max := 0.0
	var band_step_max := 0.0
	var previous: Image = null
	var still_count := 0
	for step in 41:
		tracked.position = Vector3(-0.0 + 0.01 * step, 1.7, 0.0)
		await h.frames(2)
		var img := await h.capture()
		if previous != null:
			for py in range(0, SIZE.y, 3):
				for px in range(0, SIZE.x, 3):
					var xz := pixel_to_xz(Vector2i(px, py), centre, pixel)
					# Distance to the walker over the whole walk.
					var d_min := xz.distance_to(Vector2(clampf(xz.x, 0.0, 0.4), 0.0))
					var d_max := maxf(xz.distance_to(Vector2(0.0, 0.0)), xz.distance_to(Vector2(0.4, 0.0)))
					var change := absf(img.get_pixel(px, py).r - previous.get_pixel(px, py).r) * scale
					if d_max < morph0.x - 0.05:
						still_max = maxf(still_max, change)
						still_count += 1
					elif d_min > morph0.x and d_max < morph0.y:
						band_step_max = maxf(band_step_max, change)
		previous = img
	print("  innermost ring (%d samples): largest height change %.4f mm; morph band: largest change per 1 cm step %.3f mm" % [still_count, still_max * 1000.0, band_step_max * 1000.0])
	check(still_count > 10000 and still_max < 0.00002, "near the camera the geometry does not move at all while the camera walks")
	# A 1 cm step moves the morph by 2.6 % of its 0.38 m band; with 5 cm of relief that bounds the
	# change at about 1.3 mm.
	check(band_step_max < 0.002, "in the morph band it changes by less than 2 mm per 1 cm step (no pops when the grid snaps)")
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(0, 0.1, 0, 0))


# --- 4. Seamless edge --------------------------------------------------------------------------

## A gravel ground with its field (all features on, lit) and the same ground with the field
## hidden: around the field's edge, where its relief has faded out, both must look the same,
## and beyond it they must be identical.
func test_edge_seam() -> void:
	await _edge_seam(Vector4.ZERO, 0.01, 0.005)


## The same under weather (rain, snow cover and puddles at once): the field applies its layers'
## surface effects as the ground material does.
func test_edge_seam_weather() -> void:
	GADSGlobals.set_value(GADSGlobals.WEATHER, Vector4(0.3, 0.35, 0.3, 0.0))
	await _edge_seam(Vector4(0.3, 0.35, 0.3, 0.0), 0.02, 0.01)
	GADSGlobals.set_value(GADSGlobals.WEATHER, Vector4.ZERO)


func _edge_seam(weather: Vector4, inner_limit: float, band_limit: float) -> void:
	var results := []
	for with_field in [true, false]:
		h.new_lit_scene(Color(0.2, 0.21, 0.24))
		var mat := GADSMaterials.from_texture_set("res://demo/textures/clean_pebbles", GADSMaterials.Mapping.WORLD, {"height_center": 0.0})
		var plane := PlaneMesh.new()
		plane.size = Vector2(80, 80)
		var mi := MeshInstance3D.new()
		mi.mesh = plane
		mi.material_override = mat
		h.scene.add_child(mi)
		var sun := h.add_sun(30.0, 50.0, true, 40.0)
		sun.light_energy = 1.4
		var cam := h.add_camera(Vector3(0.0, 1.7, 0.0), Vector3(0.0, 0.2, -20.0), 70.0)
		var f := GADSDisplacementField3D.new()
		f.layers = [mat]
		f.bake_on_ready = false
		f.camera = cam
		h.scene.add_child(f)
		f.set_quality(GADSMaterials.Quality.POM_SELF_SHADOW)
		f.visible = with_field
		await h.frames(8)
		results.append(await h.capture())
	# The second scene's camera and field (still alive) have the same transform and settings.
	var cam := h.scene.find_children("*", "Camera3D", true, false)[0] as Camera3D
	var f := h.scene.find_children("*", "GADSDisplacementField3D", true, false)[0] as GADSDisplacementField3D
	var fade := f.get_fade_range()
	var band_diff := 0.0
	var band_n := 0
	var inner := []
	var beyond := []
	for py in range(0, SIZE.y, 2):
		for px in range(0, SIZE.x, 2):
			var o := cam.project_ray_origin(Vector2(px, py) + Vector2(0.5, 0.5))
			var d := cam.project_ray_normal(Vector2(px, py) + Vector2(0.5, 0.5))
			if d.y >= -0.01:
				continue
			var hit := o + d * (-o.y / d.y)
			var dist := Vector2(hit.x, hit.z).distance_to(Vector2(o.x, o.z))
			var a := Harness.luminance((results[0] as Image).get_pixel(px, py))
			var b := Harness.luminance((results[1] as Image).get_pixel(px, py))
			var origin := f.snapped_origin(cam.global_position)
			var in_grid := absf(hit.x - origin.x) < f.get_reach() and absf(hit.z - origin.z) < f.get_reach()
			if dist > fade.y - 1.0 and dist < fade.y and in_grid:
				band_diff += absf(a - b) / maxf(b, 0.01)
				band_n += 1
			elif dist > 2.0 and dist < fade.x and in_grid:
				inner.append(absf(a - b) / maxf(b, 0.01))
			elif absf(hit.x - origin.x) > f.get_reach() + 0.5 or absf(hit.z - origin.z) > f.get_reach() + 0.5:
				beyond.append(absf(a - b) / maxf(b, 0.01))
	var mean_band := band_diff / maxf(band_n, 1.0)
	var inner_mean := 0.0
	for v: float in inner:
		inner_mean += v
	inner_mean /= maxf(inner.size(), 1.0)
	print("  inside the grid (2 m to the fade, %d px): mean luminance difference %.2f %%, median %.2f %%" % [inner.size(), inner_mean * 100.0, percentile(inner, 0.5) * 100.0])
	print("  %d pixels in the last metre before the relief fades out: mean luminance difference %.2f %%; beyond the grid (%d px): 99.9th percentile %.3f %%, largest %.3f %%" % [
			band_n, mean_band * 100.0, beyond.size(), percentile(beyond, 0.999) * 100.0, percentile(beyond, 1.0) * 100.0])
	# The field marches the same relief from the same ground as the ground material: they differ
	# only by float rounding and the proxy's coverage (0.15 % / 0.08 % measured; with the relief
	# shifted up by `lift` it was 16 % / 3 %).
	var label := "" if weather == Vector4.ZERO else " (rain, snow and puddles)"
	check(inner.size() > 10000 and inner_mean < inner_limit, "inside the grid the field shades like the parallax ground (within %.0f %%)%s" % [inner_limit * 100.0, label])
	check(band_n > 1000 and mean_band < band_limit, "at its edge the field looks like the parallax ground it covers (within %.1f %%)%s" % [band_limit * 100.0, label])
	check(beyond.size() > 10000 and percentile(beyond, 0.999) < 0.001, "beyond the grid nothing changes%s" % label)


# --- 5. Ground bake ----------------------------------------------------------------------------

static func terrain(x: float, z: float) -> float:
	return 0.6 * sin(x / 3.1) * cos(z / 2.3) + 0.25 * sin((x + 2.0 * z) / 1.7)


## Height of the piecewise-linear heightfield mesh built by demo_builder.heightfield() (same
## vertices, diagonal a-c of each cell) at (x, z).
static func mesh_height(x: float, z: float, size: float, step: float) -> float:
	var gx := (x + size * 0.5) / step
	var gz := (z + size * 0.5) / step
	var i := floorf(gx)
	var j := floorf(gz)
	var fx := gx - i
	var fz := gz - j
	var x0 := -size * 0.5 + i * step
	var z0 := -size * 0.5 + j * step
	var a := terrain(x0, z0)
	var b := terrain(x0 + step, z0)
	var c := terrain(x0 + step, z0 + step)
	var d := terrain(x0, z0 + step)
	# Triangles (a, b, c) and (a, c, d): split along the a-c diagonal.
	if fx >= fz:
		return a + (b - a) * fx + (c - b) * fz
	return a + (c - d) * fx + (d - a) * fz


func test_ground_bake() -> void:
	h.new_debug_scene()
	var size := 16.0
	var step := 0.25
	var mesh := Builder.heightfield(Vector2(size, size), step, func(x: float, z: float) -> float: return terrain(x, z))
	var ground := MeshInstance3D.new()
	ground.mesh = mesh
	ground.add_to_group(&"gads_bake_test")
	h.scene.add_child(ground)
	var strip_mat := StandardMaterial3D.new()
	var strip := MeshInstance3D.new()
	var strip_mesh := PlaneMesh.new()
	strip_mesh.size = Vector2(2.0, 12.0)
	strip.mesh = strip_mesh
	strip.material_override = strip_mat
	strip.position = Vector3(3.0, 1.5, 0.0)
	strip.add_to_group(&"gads_bake_test")
	h.scene.add_child(strip)
	await h.frames(2)
	var meshes := GADSGroundBake.collect_ground(self, &"gads_bake_test")
	var t0 := Time.get_ticks_msec()
	var bake := await GADSGroundBake.bake(meshes, [strip_mat], 0.05)
	var ms := Time.get_ticks_msec() - t0
	check(bake != null and bake.get_size() == Vector2i(320, 320), "a 16 x 16 m ground bakes into 320 x 320 texels of 5 cm (%d ms)" % ms)
	if bake == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	var errors := []
	for i in 2000:
		var x := rng.randf_range(-7.5, 7.5)
		var z := rng.randf_range(-7.5, 7.5)
		if x > 1.8 and x < 4.2:
			continue # the strip covers the terrain there
		errors.append(absf(bake.sample_height(Vector2(x, z)) - mesh_height(x, z, size, step)))
	var p99 := percentile(errors, 0.99)
	var worst := percentile(errors, 1.0)
	print("  %d points against the mesh surface: 99th percentile %.2f mm, largest %.2f mm" % [errors.size(), p99 * 1000.0, worst * 1000.0])
	check(p99 < 0.003 and worst < 0.008, "the baked height follows the mesh within 3 mm (99 %) and 8 mm (largest, at creases)")
	var strip_ok := true
	var ground_ok := true
	for i in 200:
		var zs := rng.randf_range(-5.5, 5.5)
		strip_ok = strip_ok and bake.sample_weights(Vector2(3.0 + rng.randf_range(-0.8, 0.8), zs)).r > 0.99
		strip_ok = strip_ok and absf(bake.sample_height(Vector2(3.0 + rng.randf_range(-0.8, 0.8), zs)) - 1.5) < 0.001
		ground_ok = ground_ok and bake.sample_weights(Vector2(rng.randf_range(-7.0, 1.0), rng.randf_range(-7.0, 7.0))).r < 0.01
	check(strip_ok, "the top-most surface wins (a layer strip 1.5 m up) and carries its layer")
	check(ground_ok, "ground that is not a layer carries no layer weight")


# --- 6. Pebbles --------------------------------------------------------------------------------

## Pebbles are placed from their world cell, so moving the camera (and the cell window with it)
## must leave the pebbles near it exactly where they were.
func test_pebbles() -> void:
	h.new_lit_scene(Color(0.3, 0.3, 0.3))
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40, 40)
	ground.mesh = plane
	var green := StandardMaterial3D.new()
	green.albedo_color = Color(0.05, 0.3, 0.05)
	ground.material_override = green
	h.scene.add_child(ground)
	h.add_sun(60.0, 20.0, false)
	var tracked := add_tracked_camera(Vector3(0.0, 1.7, 0.0))
	var field := Harness.make_wave_field(64)
	var f := add_field(field, 1.0, 0.0, tracked)
	var pebbles := GADSPebbleScatter3D.new()
	pebbles.valley_bias = 0.0
	pebbles.radius = 8.0
	f.add_child(pebbles)
	add_top_camera(Vector2(0.4, 0.3), 0.004)
	await h.frames(4)
	f.get_mesh_instance().visible = false
	await h.frames(4)
	var before := await h.capture()
	var window_before: Vector2 = pebbles.get_particles().process_material.get_shader_parameter("window_cell")
	# Across cell boundaries in x and z (1 m cells), so the window really moves; both camera
	# positions stay closer than half the radius (4 m) to every pebble in view, where the pebbles
	# start to shrink with distance.
	tracked.position = Vector3(1.2, 1.7, -0.3)
	await h.frames(6)
	var after := await h.capture()
	var window_after: Vector2 = pebbles.get_particles().process_material.get_shader_parameter("window_cell")
	check(window_after - window_before == Vector2(1, -1), "the cell window moved with the camera (%s -> %s)" % [window_before, window_after])
	var pebble_px := 0
	var changed := 0
	for py in range(0, SIZE.y, 2):
		for px in range(0, SIZE.x, 2):
			var a := before.get_pixel(px, py)
			var b := after.get_pixel(px, py)
			if a.g < a.r + 0.05 or a.g < a.b + 0.05:
				pebble_px += 1
			if maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b)) > 0.002:
				changed += 1
	print("  pebble pixels %d; pixels that changed when the camera moved 1.24 m: %d" % [pebble_px, changed])
	check(pebble_px > 500, "pebbles are drawn around the camera")
	check(changed == 0, "they stay exactly where they are when the camera (and the cell window) moves")


# --- 7. Lifetime --------------------------------------------------------------------------------

## The demo's gravel path through presets, viewport resizes, a second viewport and teardown; the
## log scan (tests/run_all.py) then checks the exit for leaked RIDs and objects.
func test_lifetime() -> void:
	h.clear_scene()
	await h.frames(2)
	var scene := Builder.build(0)
	h.viewport.add_child(scene)
	var gads := scene.get_node("GADSManager") as GADSManager
	(scene.get_node("Camera") as Camera3D).current = true
	for preset in [GADSSettings.Preset.ULTRA, GADSSettings.Preset.OFF, GADSSettings.Preset.HIGH, GADSSettings.Preset.LOW, GADSSettings.Preset.ULTRA]:
		gads.preset = preset
		await h.frames(6)
	for size in [Vector2i(1280, 720), Vector2i(320, 180), SIZE]:
		h.viewport.size = size
		await h.frames(4)
	var second := SubViewport.new()
	second.size = Vector2i(320, 180)
	second.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	second.world_3d = h.viewport.find_world_3d()
	var cam2 := Camera3D.new()
	second.add_child(cam2)
	root.add_child(second)
	cam2.look_at_from_position(Vector3(4, 3, 6), Vector3.ZERO)
	cam2.current = true
	await h.frames(6)
	var img := second.get_texture().get_image()
	check(img != null and not img.is_invisible(), "a second viewport on the same world renders")
	second.queue_free()
	var field := scene.find_children("*", "GADSDisplacementField3D", true, false)[0] as GADSDisplacementField3D
	check(field.get_mesh_instance().get_parent() == field, "the field kept its mesh through presets and resizes")
	scene.queue_free()
	await h.frames(3)
	check(get_nodes_in_group(&"gads_field").is_empty() and get_nodes_in_group(&"gads_scatter").is_empty()
			and get_nodes_in_group(&"gads_manager").is_empty(), "freeing the scene leaves no field, scatter or manager behind")
	# A scene change while a field bakes its ground: nothing may resume on the freed field (the
	# log scan of tests/run_all.py fails the suite on the engine's "class instance is gone" error).
	var baking := Builder.build(0)
	h.viewport.add_child(baking)
	await h.frames(1)
	var baking_field := baking.find_children("*", "GADSDisplacementField3D", true, false)[0] as GADSDisplacementField3D
	check(baking_field.is_baking(), "the gravel path's field bakes its ground at runtime")
	baking.queue_free()
	await h.frames(10)
	check(root.find_children("*", "SubViewport", true, false).size() == 1, "the capture viewport of an abandoned bake is freed")


# --- 8. Demo scenes -----------------------------------------------------------------------------

## Triangles of [param mesh] whose front face (clockwise, Godot's convention) looks down: the
## camera above culls them, only the cull-disabled ground bake would see them.
static func count_back_facing_up(mesh: Mesh) -> int:
	var count := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if idx.is_empty():
			idx.resize(v.size())
			for i in v.size():
				idx[i] = i
		for i in range(0, idx.size(), 3):
			var a := v[idx[i]]
			var front := (v[idx[i + 2]] - a).cross(v[idx[i + 1]] - a)
			if front.y <= 0.0:
				count += 1
	return count


func test_demo_scenes() -> void:
	h.clear_scene()
	h.make_viewport(SIZE, false)
	for index in Builder.SCENE_NAMES.size():
		var scene := Builder.build(index)
		var start := Time.get_ticks_msec()
		h.viewport.add_child(scene)
		(scene.get_node("Camera") as Camera3D).current = true
		var gads := scene.get_node("GADSManager") as GADSManager
		for field: GADSDisplacementField3D in scene.find_children("*", "GADSDisplacementField3D", true, false):
			if field.is_baking():
				await field.baked
			if field.ground_bake != null:
				print("  %s: ground bake of %s texels in %d ms" % [Builder.SCENE_NAMES[index], field.ground_bake.get_size(), Time.get_ticks_msec() - start])
		var back_facing := 0
		for node in scene.find_children("*", "MeshInstance3D", true, false):
			if node.is_in_group(&"gads_ground"):
				back_facing += count_back_facing_up((node as MeshInstance3D).mesh)
		check(back_facing == 0, "%s: every ground triangle faces up (%d do not)" % [Builder.SCENE_NAMES[index], back_facing])
		var ok := true
		for preset in [GADSSettings.Preset.OFF, GADSSettings.Preset.LOW, GADSSettings.Preset.MEDIUM, GADSSettings.Preset.HIGH, GADSSettings.Preset.ULTRA]:
			gads.preset = preset
			await h.frames(12)
			var img := await h.capture()
			ok = ok and img != null and not img.is_invisible()
		check(ok, "%s renders at every preset" % Builder.SCENE_NAMES[index])
		scene.queue_free()
		await h.frames(3)
	h.make_viewport(SIZE, true)


## The demo's fly camera moves while the right mouse button and W are held. (Its script is
## attached by demo_main.gd; attached after the camera is ready, it never processes.)
func test_demo_camera() -> void:
	h.clear_scene()
	var demo: Node = (load("res://demo/demo_main.tscn") as PackedScene).instantiate()
	h.viewport.add_child(demo)
	await h.frames(3)
	var cam := (demo.get("scene") as Node).get_node("Camera") as Camera3D
	var start := cam.global_position
	var forward := -cam.global_basis.z
	var events: Array[InputEvent] = []
	var button := InputEventMouseButton.new()
	button.button_index = MOUSE_BUTTON_RIGHT
	button.button_mask = MOUSE_BUTTON_MASK_RIGHT
	events.append(button)
	var key := InputEventKey.new()
	key.keycode = KEY_W
	key.physical_keycode = KEY_W
	events.append(key)
	for e in events:
		e.set("pressed", true)
		Input.parse_input_event(e)
	await h.frames(10)
	var moved := (cam.global_position - start).dot(forward)
	for e in events:
		e.set("pressed", false)
		Input.parse_input_event(e)
	await h.frames(2)
	print("  moved %.3f m forward" % moved)
	check(moved > 0.02, "holding the right mouse button and W flies the demo camera forward")
	for field: GADSDisplacementField3D in demo.find_children("*", "GADSDisplacementField3D", true, false):
		if field.is_baking():
			await field.baked
	demo.queue_free()
	await h.frames(3)

## Relief queries for gameplay: get_surface_height() is the ground plus the layers' relief at full
## resolution (what the march draws near the camera) minus the runtime deformation, NAN off the
## ground data; get_surface_normal() follows its slope; raycast_surface() meets it where the height
## says.
func test_surface_queries() -> void:
	var tile := 1.28
	var amp := 0.04
	var field := Harness.make_wave_field(256)
	h.new_debug_scene()
	var tracked := add_tracked_camera(Vector3(0.37, 1.7, -0.23))
	var f := add_field(field, tile, amp, tracked)
	var texel := 0.1
	var cells := Vector2i(100, 100)
	var bake_origin := Vector2(-5.0, -5.0)
	var heights := PackedFloat32Array()
	var ids := PackedInt32Array()
	for y in cells.y:
		for x in cells.x:
			var p := bake_origin + (Vector2(x, y) + Vector2(0.5, 0.5)) * texel
			heights.append(0.02 * p.x - 0.01 * p.y)
			ids.append(0)
	f.ground_bake = GADSGroundBake.from_arrays(cells, heights, ids, bake_origin, texel)
	await h.frames(2)
	var want := func(xz: Vector2) -> float:
		return f.ground_bake.sample_height(xz) + amp * Harness.sample_field(field, xz / tile)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var worst := 0.0
	for i in 400:
		var xz := Vector2(rng.randf_range(-4.0, 4.0), rng.randf_range(-4.0, 4.0))
		worst = maxf(worst, absf(f.get_surface_height(Vector3(xz.x, 0.0, xz.y)) - want.call(xz)))
	print("  surface height at 400 points: largest difference from ground + relief %.4f mm" % (worst * 1000.0))
	check(worst < 1e-4, "get_surface_height() is the ground plus the layer's relief at full resolution")
	check(is_nan(f.get_surface_height(Vector3(50, 0, 50))), "and NAN off the ground data")
	var p := Vector3(0.61, 0.0, -0.37)
	var n := f.get_surface_normal(p, 0.002)
	var dx := (float(want.call(Vector2(p.x + 0.002, p.z))) - float(want.call(Vector2(p.x - 0.002, p.z)))) / 0.004
	var dz := (float(want.call(Vector2(p.x, p.z + 0.002))) - float(want.call(Vector2(p.x, p.z - 0.002)))) / 0.004
	check(n.dot(Vector3(-dx, 1.0, -dz).normalized()) > 0.9999, "get_surface_normal() follows its slope")
	var from := Vector3(-0.8, 1.5, 0.4)
	var to := Vector3(0.9, -0.5, -0.2)
	var hit := f.raycast_surface(from, to)
	var on_ray := false
	var gap := INF
	var before_above := false
	if not hit.is_empty():
		var hp: Vector3 = hit["position"]
		var t := from.distance_to(hp) / from.distance_to(to)
		on_ray = from.lerp(to, t).distance_to(hp) < 1e-5
		gap = absf(hp.y - f.get_surface_height(hp))
		var earlier := from.lerp(to, maxf(t - 0.01, 0.0))
		before_above = earlier.y > f.get_surface_height(earlier)
	print("  ray hit %s, %.5f mm from the surface" % [hit.get("position", "none"), gap * 1000.0])
	check(on_ray and gap < 1e-4 and before_above, "raycast_surface() meets the relief on the ray, coming from above")
	check(f.raycast_surface(Vector3(0, 2, 0), Vector3(1, 1, 0)).is_empty(), "a ray that stays above it meets nothing")
	var deform := GADSDeformationField.new()
	deform.size_m = 8.0
	deform.resolution = 256
	h.scene.add_child(deform)
	var c := Vector3(0.5, 0.0, 0.5)
	var plain := f.get_surface_height(c)
	deform.stamp(c, 0.3, 0.05)
	var pressed := f.get_surface_height(c)
	print("  deformation: %.4f m pressed %.4f m" % [plain - pressed, deform.get_depth(c)])
	check(absf(plain - pressed - deform.get_depth(c)) < 1e-6 and deform.get_depth(c) > 0.04, "the runtime deformation presses it down")
	deform.queue_free()
	await process_frame
