extends SceneTree
## Tests of the baked displacement (GADSMeshBaker, GADSMeshInstance3D and the native
## tessellator), headed because some compare renders:
##     python tools/godot.py --script tests/bake_tests.gd [-- --only=name,name]
## Geometry is checked against the height field it was baked from (accuracy, adaptivity, closed
## surfaces across seams and hard edges, budget, determinism, scale, triangle shape, normals,
## tangents, the shaders' rest data, LODs); the node's cache, staleness, collision and save / load;
## and renders of a baked mesh against the same material's parallax. Exit code 0 = all passed.
## With --headless (a dummy renderer) everything but the renders runs.

const Harness := preload("res://tests/lib/gads_harness.gd")
const CACHE_DIR := "user://gads_bake_tests"
const SIZE := Vector2i(640, 360)

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
	if not GADSMeshBaker.is_available():
		# The library ships for Linux and Windows x86_64; elsewhere there is nothing to test.
		var expected := OS.get_name() in ["Linux", "Windows"] and Engine.get_architecture_name() == "x86_64"
		print("bake tests: native library not loaded%s" % (" (it should be on this platform)" if expected else ", skipped"))
		print("\nbake tests: %d passed, %d failed" % [0, 1 if expected else 0])
		quit(1 if expected else 0)
		return
	_remove_cache()
	await process_frame # _initialize runs before the root enters the tree.
	await _test("library_matches_sources", test_library_matches_sources)
	await _test("follows_the_height_field", test_accuracy)
	await _test("detail_layer_baked", test_detail_layer)
	await _test("layered_material_baked", test_layered)
	await _test("refines_only_where_the_relief_is", test_adaptivity)
	await _test("vector_displacement", test_vector_displacement)
	await _test("closed_meshes_stay_closed", test_watertight)
	await _test("locked_borders_stay", test_locked_borders)
	await _test("triangle_budget", test_budget)
	await _test("view_dependent_refinement", test_view_dependent)
	await _test("deterministic", test_determinism)
	await _test("scaled_and_rotated_nodes", test_transform)
	await _test("triangle_shape", test_angles)
	await _test("normals_tangents_and_rest_data", test_attributes)
	await _test("lods", test_lods)
	await _test("clusters", test_clusters)
	await _test("cancel", test_cancel)
	await _test("node_bake_cache_and_clear", test_node)
	await _test("staleness", test_staleness)
	await _test("collision", test_collision)
	await _test("save_and_load", test_save_load)
	await _test("cluster_node", test_cluster_node)
	await _test("profiler", test_profiler)
	await _test("diagnostics_overlay", test_diagnostics)
	await _test("export", test_export)
	await _test("sculpt", test_sculpt)
	await _test("bake_cache", test_bake_cache)
	await _test("vertex_paint", test_vertex_paint)
	await _test("streamed_bake", test_stream)
	await _test("skinned", test_skinned)
	await _test("blend_shapes", test_blend_shapes)
	await _test("import_options", test_import)
	if DisplayServer.get_name() != "headless":
		await _test("renders_like_parallax", test_render)
		await _test("silhouette", test_silhouette)
		await _test("geometry_to_parallax_by_distance", test_geometry_range)
		await _test("runtime_tessellation_follows_the_camera", test_runtime_tessellation)
		await _test("runtime_budget_and_adaptive_quality", test_runtime_budget)
		await _test("prop_geometry_near_the_camera", test_prop_geometry)
	print("\nbake tests: %d passed, %d failed" % [_passed, _failed])
	h.clear_scene()
	h.viewport.queue_free()
	_remove_cache()
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
	GADSGlobals.set_value(GADSGlobals.POM_STEPS, Vector4(8, 24, 3, 0))
	GADSGlobals.set_value(GADSGlobals.POM_RANGE, Vector4(1000, 2000, -10, 99))
	GADSGlobals.set_value(GADSGlobals.SHADOW, Vector4(8, 20, 0, 0))
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(0, 0.1, 0, 0))
	await fn.call()


func check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("  ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL %s" % what)


func _remove_cache() -> void:
	var dir := DirAccess.open(CACHE_DIR)
	if dir == null:
		return
	for f in dir.get_files():
		dir.remove(f)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CACHE_DIR))


# --- Fixtures -----------------------------------------------------------------------------------

## A Gaussian bump in the middle of the tile: h = exp(-r^2 / (2 sigma^2)), sigma in uv.
static func bump_field(size: int, sigma: float) -> Dictionary:
	var data := PackedFloat32Array()
	data.resize(size * size)
	for y in size:
		for x in size:
			var d := Vector2((x + 0.5) / size - 0.5, (y + 0.5) / size - 0.5)
			data[y * size + x] = exp(-d.length_squared() / (2.0 * sigma * sigma))
	return Harness.field_from_data(data, size)


## A normal map that matches field on a tile of tile_m metres with relief depth amp (m): the
## GADS convention (x along +u, y along -v, see gads_apply_normal_map).
static func normal_map_of(field: Dictionary, tile_m: float, amp: float) -> ImageTexture:
	var size: int = field["size"]
	var data: PackedFloat32Array = field["data"]
	var texel_m := tile_m / size
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var du := (data[y * size + posmod(x + 1, size)] - data[y * size + posmod(x - 1, size)]) * amp / (2.0 * texel_m)
			var dv := (data[posmod(y + 1, size) * size + x] - data[posmod(y - 1, size) * size + x]) * amp / (2.0 * texel_m)
			var n := Vector3(-du, dv, 1.0).normalized()
			img.set_pixel(x, y, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func uv_material(field: Dictionary, amp: float, params := {}) -> ShaderMaterial:
	var p := {"height_m": amp, "height_center": 0.0}
	p.merge(params, true)
	return GADSMaterials.create(GADSMaterials.Mapping.UV, {"height": ImageTexture.create_from_image(field["image"])}, p, GADSMaterials.Quality.POM)


static func plane(size := 2.0) -> PlaneMesh:
	var m := PlaneMesh.new()
	m.size = Vector2(size, size)
	return m


## Bakes mesh with one material on every surface; returns the baker (check .mesh / .error).
func bake_with(mesh: Mesh, material: Material, settings: Dictionary, xform := Transform3D.IDENTITY) -> GADSMeshBaker:
	var materials: Array[Material] = []
	for s in mesh.get_surface_count():
		materials.append(material)
	var baker := GADSMeshBaker.new()
	var full := {"max_error": 0.0005, "max_triangles": 200000, "lods": false}
	full.merge(settings, true)
	baker.setup(mesh, materials, xform, full)
	baker.run()
	return baker


static func triangles_of(mesh: Mesh) -> Array:
	var out := []
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for i in range(0, idx.size(), 3):
			out.append([v[idx[i]], v[idx[i + 1]], v[idx[i + 2]]])
	return out


static func triangle_count(mesh: Mesh) -> int:
	var n := 0
	for s in mesh.get_surface_count():
		n += (mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	return n


# --- Tests --------------------------------------------------------------------------------------

## The shipped library embeds a hash of native/src and native/thirdparty (tools/build_native.py
## --hash): a source change without a rebuild fails here.
func test_library_matches_sources() -> void:
	var files: Array[String] = []
	for top in ["src", "thirdparty"]:
		_collect_sources("res://native/" + top, top, files)
	files.sort()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	for rel in files:
		ctx.update((rel + "\n").to_utf8_buffer())
		ctx.update(FileAccess.get_file_as_bytes("res://native/" + rel))
	var source_hash := ctx.finish().hex_encode().left(16)
	var built: String = ClassDB.class_call_static("GADSTessellator", "get_build_hash")
	print("  sources %s, library %s" % [source_hash, built])
	check(built == source_hash, "the library was built from the current native sources (python tools/build_native.py)")
	# Every library the extension ships (the other platforms' too) embeds the same hash.
	var config := ConfigFile.new()
	config.load("res://addons/gads/native/gads.gdextension")
	var stale := []
	for key in config.get_section_keys("libraries"):
		var path: String = config.get_value("libraries", key)
		if not _embeds(FileAccess.get_file_as_bytes(path), source_hash):
			stale.append(key)
	check(config.get_section_keys("libraries").size() >= 3 and stale.is_empty(),
		"every shipped library (%s) was built from them (stale: %s)" % [", ".join(config.get_section_keys("libraries")), stale])


## Whether [param bytes] contain [param text] (ASCII) at a byte boundary.
static func _embeds(bytes: PackedByteArray, text: String) -> bool:
	var hex := bytes.hex_encode()
	var needle := text.to_ascii_buffer().hex_encode()
	var at := hex.find(needle)
	while at >= 0 and at % 2 != 0:
		at = hex.find(needle, at + 1)
	return at >= 0


func _collect_sources(dir_path: String, rel: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for f in dir.get_files():
		if f.get_extension() in ["h", "hpp", "c", "cpp"] and not f.ends_with(".gen.h"):
			out.append(rel + "/" + f)
	for d in dir.get_directories():
		_collect_sources(dir_path + "/" + d, rel + "/" + d, out)


func test_accuracy() -> void:
	var field := bump_field(256, 0.08)
	var amp := 0.06
	var tolerance := 0.0005
	var baker := bake_with(plane(), uv_material(field, amp), {"max_error": tolerance})
	check(baker.mesh != null, "a plane bakes (%s)" % baker.error)
	if baker.mesh == null:
		return
	# Points inside the triangles against the field at the same uv.
	var arrays := baker.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var worst := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in range(0, idx.size(), 3):
		for k in 3:
			var a := rng.randf()
			var b := rng.randf() * (1.0 - a)
			var c := 1.0 - a - b
			var p := v[idx[i]] * a + v[idx[i + 1]] * b + v[idx[i + 2]] * c
			var t := uv[idx[i]] * a + uv[idx[i + 1]] * b + uv[idx[i + 2]] * c
			worst = maxf(worst, absf(p.y - amp * Harness.sample_field(field, t)))
	print("  %d triangles, largest distance to the height field %.3f mm (tolerance %.1f mm)" % [idx.size() / 3, worst * 1000.0, tolerance * 1000.0])
	check(worst < 2.0 * tolerance, "the geometry stays within twice the tolerance of the height field (footprint filtering adds a little)")
	var peak := 0.0
	for p in v:
		peak = maxf(peak, p.y)
	check(absf(peak - amp) < 0.002, "the bump's top is %.1f mm high (%.1f mm)" % [peak * 1000.0, amp * 1000.0])


## A detail layer (a wave field repeated 4 times, 4 mm deep) on the bump: the bake follows the
## combined relief, as the shaders draw it.
func test_detail_layer() -> void:
	var field := bump_field(256, 0.08)
	var wave := Harness.make_wave_field(128)
	var amp := 0.06
	var detail_amp := 0.004
	var tolerance := 0.0005
	var mat := uv_material(field, amp, {"detail_height_m": detail_amp, "detail_scale": 4.0})
	mat.set_shader_parameter("detail_height_texture", ImageTexture.create_from_image(wave["image"]))
	var baker := bake_with(plane(), mat, {"max_error": tolerance})
	var plain := bake_with(plane(), uv_material(field, amp), {"max_error": tolerance})
	check(baker.mesh != null, "a plane with a detail layer bakes (%s)" % baker.error)
	if baker.mesh == null:
		return
	var surface := {"amp": amp, "center": 0.0, "field": field, "detail": {"field": wave, "amp": detail_amp, "scale": 4.0}}
	var arrays := baker.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var worst := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in range(0, idx.size(), 3):
		var a := rng.randf()
		var b := rng.randf() * (1.0 - a)
		var c := 1.0 - a - b
		var p := v[idx[i]] * a + v[idx[i + 1]] * b + v[idx[i + 2]] * c
		var t := uv[idx[i]] * a + uv[idx[i + 1]] * b + uv[idx[i + 2]] * c
		worst = maxf(worst, absf(p.y - Harness.relief_value(surface, t)))
	var n := triangle_count(baker.mesh)
	print("  %d triangles with the detail layer, %d without; largest distance to the combined field %.3f mm" % [n, triangle_count(plain.mesh), worst * 1000.0])
	check(worst < 2.0 * tolerance, "the geometry follows the combined relief within twice the tolerance")
	check(n > 2 * triangle_count(plain.mesh), "the detail layer is refined too")


## A layered material: a wave layer at half strength everywhere over the bump, blended by height,
## and a second layer that vertex colour G paints on one half of a subdivided plane. The bake
## follows the blended relief the shaders draw.
func test_layered() -> void:
	var field := bump_field(256, 0.08)
	var wave := Harness.make_wave_field(128)
	var amp := 0.06
	var tolerance := 0.0005
	var wave_tex := ImageTexture.create_from_image(wave["image"])
	var mat := GADSMaterials.create_layered(GADSMaterials.Mapping.UV, {"height": ImageTexture.create_from_image(field["image"])},
			{"height_m": amp, "height_center": 0.0},
			[{"height": wave_tex, "height_m": 0.02, "scale": 2.0, "mask": GADSMaterials.LayerMask.EVERYWHERE, "amount": 0.5, "blend_width": 0.15},
			{"height": wave_tex, "height_m": 0.04, "scale": 3.0, "mask": GADSMaterials.LayerMask.VERTEX_G, "amount": 1.0, "blend_width": 0.1}],
			GADSMaterials.Quality.POM)
	# A plane whose vertices left of x = 0 carry G = 0, right of it G = 1.
	var source := PlaneMesh.new()
	source.size = Vector2(2, 2)
	source.subdivide_width = 7
	source.subdivide_depth = 7
	var arrays := source.get_mesh_arrays()
	var colors := PackedColorArray()
	for p: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
		colors.append(Color(1, 1.0 if p.x > 0.01 else 0.0, 1, 1))
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var baker := bake_with(mesh, mat, {"max_error": tolerance})
	check(baker.mesh != null, "a layered material bakes (%s)" % baker.error)
	if baker.mesh == null:
		return
	var out := baker.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = out[Mesh.ARRAY_VERTEX]
	var uv: PackedVector2Array = out[Mesh.ARRAY_TEX_UV]
	var col: PackedColorArray = out[Mesh.ARRAY_COLOR]
	var idx: PackedInt32Array = out[Mesh.ARRAY_INDEX]
	var worst := 0.0
	var errors := []
	var rng := RandomNumberGenerator.new()
	rng.seed = 9
	for i in range(0, idx.size(), 3):
		var a := rng.randf()
		var b := rng.randf() * (1.0 - a)
		var c := 1.0 - a - b
		var p := v[idx[i]] * a + v[idx[i + 1]] * b + v[idx[i + 2]] * c
		var t := uv[idx[i]] * a + uv[idx[i + 1]] * b + uv[idx[i + 2]] * c
		var g := col[idx[i]].g * a + col[idx[i + 1]].g * b + col[idx[i + 2]].g * c
		var surface := {"amp": amp, "center": 0.0, "field": field, "layers": [
			{"field": wave, "amp": 0.02, "scale": 2.0, "mask": 0.5, "blend_width": 0.15},
			{"field": wave, "amp": 0.04, "scale": 3.0, "mask": g, "blend_width": 0.1}]}
		var e := absf(p.y - Harness.relief_value(surface, t))
		errors.append(e)
		worst = maxf(worst, e)
	errors.sort()
	var p95: float = errors[int(errors.size() * 0.95)]
	var reported: float = baker.stats["max_error_left"]
	print("  %d triangles; distance to the blended relief: 95th percentile %.3f mm, largest %.3f mm; the bake reports %.3f mm left where edges reached a texel" % [
		idx.size() / 3, p95 * 1000.0, worst * 1000.0, reported * 1000.0])
	check(p95 < 2.0 * tolerance, "95 % of the surface follows the height-blended layers within twice the tolerance")
	# Blend transitions sharper than a texel cannot be followed; the bake says how far off it stays.
	check(worst <= maxf(2.0 * tolerance, reported) + 0.0002, "nowhere further from the blended relief than the bake reports")
	check(col.size() == v.size(), "the vertex colours (the layer masks) are carried into the baked mesh")


func test_adaptivity() -> void:
	var field := bump_field(256, 0.06)
	var baker := bake_with(plane(), uv_material(field, 0.05), {"max_error": 0.0005})
	var near := 0
	var far := 0
	for t: Array in triangles_of(baker.mesh):
		var c: Vector3 = (t[0] + t[1] + t[2]) / 3.0
		var r := Vector2(c.x, c.z).length()
		if r < 0.3:
			near += 1
		elif r > 0.7:
			far += 1
	# Areas: inner disc 0.28 m2, outer region 4 - 1.54 = 2.46 m2.
	var density_near := near / (PI * 0.09)
	var density_far := far / (4.0 - PI * 0.49)
	print("  %d triangles within 0.3 m of the bump, %d beyond 0.7 m (density ratio %.0f)" % [near, far, density_near / maxf(density_far, 1e-6)])
	check(density_near > 20.0 * density_far, "triangles go where the relief is")
	check(baker.stats["source_triangles"] == 2 and baker.stats["triangles"] == triangle_count(baker.mesh), "statistics count the triangles")


## Every edge of a closed source mesh still has exactly two triangles after the bake (no cracks or
## T-junctions at UV seams, hard edges or poles).
func test_watertight() -> void:
	var field := Harness.make_wave_field(128)
	var tex := ImageTexture.create_from_image(field["image"])
	var sphere := SphereMesh.new()
	var cylinder := CylinderMesh.new()
	var box := BoxMesh.new()
	var cases := [
		["box, triplanar", box, GADSMaterials.Mapping.TRIPLANAR],
		["box, uv", box, GADSMaterials.Mapping.UV],
		["sphere, uv", sphere, GADSMaterials.Mapping.UV],
		["cylinder, world", cylinder, GADSMaterials.Mapping.WORLD],
	]
	for c: Array in cases:
		var mat := GADSMaterials.create(c[2], {"height": tex}, {"height_m": 0.04, "height_center": 0.5, "texture_size_m": Vector2(0.5, 0.5)}, GADSMaterials.Quality.POM)
		var baker := bake_with(c[1], mat, {"max_error": 0.001, "max_triangles": 60000})
		if baker.mesh == null:
			check(false, "%s bakes (%s)" % [c[0], baker.error])
			continue
		var edges := {}
		for t: Array in triangles_of(baker.mesh):
			var keys := [_weld(t[0]), _weld(t[1]), _weld(t[2])]
			if keys[0] == keys[1] or keys[1] == keys[2] or keys[0] == keys[2]:
				continue # Degenerate (a pole): no edge of its own.
			for k in 3:
				var a: Vector3i = keys[k]
				var b: Vector3i = keys[(k + 1) % 3]
				var key := [a, b] if [a.x, a.y, a.z] < [b.x, b.y, b.z] else [b, a]
				edges[key] = edges.get(key, 0) + 1
		var open := 0
		for key in edges:
			if edges[key] != 2:
				open += 1
		print("  %s: %d triangles, %d edges, %d not shared by exactly two" % [c[0], triangle_count(baker.mesh), edges.size(), open])
		check(open == 0, "%s stays closed" % c[0])


static func _weld(p: Vector3) -> Vector3i:
	return Vector3i((p * 1e5).round())


func test_locked_borders() -> void:
	var field := Harness.make_wave_field(128)
	var mat := uv_material(field, 0.05, {"height_center": 0.5})
	var free := bake_with(plane(), mat, {"max_error": 0.001})
	var locked := bake_with(plane(), mat, {"max_error": 0.001, "lock_borders": true})
	var moved_free := 0.0
	var moved_locked := 0.0
	for pair: Array in [[free, "free"], [locked, "locked"]]:
		for p: Vector3 in (pair[0] as GADSMeshBaker).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
			if absf(absf(p.x) - 1.0) < 1e-5 or absf(absf(p.z) - 1.0) < 1e-5:
				if pair[1] == "free":
					moved_free = maxf(moved_free, absf(p.y))
				else:
					moved_locked = maxf(moved_locked, absf(p.y))
	print("  border vertices move up to %.2f mm (free), %.4f mm (locked)" % [moved_free * 1000.0, moved_locked * 1000.0])
	check(moved_free > 0.001 and moved_locked < 1e-6, "lock_borders keeps open edges in place")


func test_budget() -> void:
	var field := Harness.make_stone_field(256, 40, 5)
	var baker := bake_with(plane(), uv_material(field, 0.05), {"max_error": 0.00005, "max_triangles": 3000})
	var n := triangle_count(baker.mesh)
	print("  %d triangles for a budget of 3000; %.2f mm left" % [n, float(baker.stats["max_error_left"]) * 1000.0])
	check(n <= 3000 and n > 2000, "the budget caps the triangle count")
	check(baker.stats["budget_reached"] and baker.stats["max_error_left"] > 0.00005, "the statistics say the budget stopped it, and how far off it is")


## View-dependent refinement: dense where the eye is, coarse far away, as fine as a fixed bake
## right at the eye.
func test_view_dependent() -> void:
	var field := Harness.make_stone_field(256, 60, 11)
	var mat := uv_material(field, 0.05)
	var m := plane(8.0)
	var fixed := bake_with(m, mat, {"max_error": 0.0005, "max_triangles": 2000000})
	var eye := Vector3(-3.5, 0.6, -3.5)
	var view := bake_with(m, mat, {"max_error": 0.0005, "max_triangles": 2000000, "view_dependent": true, "view_position": eye,
		"pixel_error": 1.0, "focal_px": 1000.0})
	var density := func(mesh: Mesh, center: Vector2, radius: float) -> float:
		var n := 0
		for t: Array in triangles_of(mesh):
			var c: Vector3 = (t[0] + t[1] + t[2]) / 3.0
			if Vector2(c.x, c.z).distance_to(center) < radius:
				n += 1
		return n / (PI * radius * radius)
	var near_fixed: float = density.call(fixed.mesh, Vector2(-3.5, -3.5), 0.4)
	var near_view: float = density.call(view.mesh, Vector2(-3.5, -3.5), 0.4)
	var far_view: float = density.call(view.mesh, Vector2(3.0, 3.0), 0.8)
	print("  fixed %d triangles, view-dependent %d; at the eye %.0f vs %.0f per m2, far corner %.0f" % [
		fixed.stats["triangles"], view.stats["triangles"], near_fixed, near_view, far_view])
	check(view.stats["triangles"] * 3 < fixed.stats["triangles"], "a view-dependent bake needs far fewer triangles")
	check(near_view > 0.7 * near_fixed, "at the eye it is about as fine as the fixed bake")
	check(near_view > 10.0 * far_view, "far from the eye it is coarse")
	# Refinement stops at a texel (min_edge_texels) as in the fixed bake, and at 2 pixels on screen
	# (min_edge_pixels): what is left is no more than the fixed bake leaves, or under 2 px far away.
	var fixed_left := float(fixed.stats["max_error_left"])
	print("  largest error left %.2f mm (%.2f px; fixed bake %.2f mm)" % [float(view.stats["max_error_left"]) * 1000.0,
		view.stats["max_pixels_left"], fixed_left * 1000.0])
	check(not view.stats["budget_reached"] and float(view.stats["max_error_left"]) <= maxf(fixed_left, 2.0 * 11.5 / 1000.0),
		"the budget did not stop it, and what is left is what the texels or a couple of pixels leave")
	var ortho := bake_with(m, mat, {"max_error": 0.0005, "max_triangles": 2000000, "view_dependent": true, "view_position": eye,
		"pixel_error": 1.0, "focal_px": 1e9})
	check(ortho.stats["triangles"] == fixed.stats["triangles"], "with an infinitely sharp view it is the fixed bake")


func test_determinism() -> void:
	var field := Harness.make_stone_field(256, 40, 9)
	var mat := uv_material(field, 0.05)
	var a := bake_with(plane(), mat, {"threads": 4})
	var b := bake_with(plane(), mat, {"threads": 4})
	var c := bake_with(plane(), mat, {"threads": 1})
	var va: PackedVector3Array = a.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var ia: PackedInt32Array = a.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	check(va == b.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] and ia == b.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX], "two bakes are identical")
	check(va == c.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] and ia == c.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX], "the thread count does not change the result")


## height_m is in metres in the world: on a node scaled by 2 the object-space displacement is half.
## Rotated onto a wall it still moves along the surface normal.
func test_transform() -> void:
	var field := bump_field(128, 0.1)
	var mat := uv_material(field, 0.05)
	var scaled := bake_with(plane(), mat, {}, Transform3D(Basis.from_scale(Vector3(2, 2, 2)), Vector3(5, 0, 0)))
	var wall := bake_with(plane(), mat, {}, Transform3D(Basis(Vector3.RIGHT, PI / 2.0), Vector3.ZERO))
	var peak_scaled := 0.0
	var peak_wall := 0.0
	var off_axis := 0.0
	for p: Vector3 in scaled.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		peak_scaled = maxf(peak_scaled, p.y)
	for p: Vector3 in wall.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]:
		peak_wall = maxf(peak_wall, p.y)
	print("  peak in object space: %.2f mm at scale 2, %.2f mm on a wall" % [peak_scaled * 1000.0, peak_wall * 1000.0])
	check(absf(peak_scaled - 0.025) < 0.001, "scale 2 halves the object-space displacement")
	check(absf(peak_wall - 0.05) < 0.001, "a rotated plane moves along its own normal")
	# The error is measured in world metres. Scaled by 2 the bump is 4 times the area at a quarter
	# of the curvature, so it needs about as many triangles; measured in object units (half the
	# displacement there) it would need about half as many.
	var unscaled := triangle_count(bake_with(plane(), mat, {}).mesh)
	var ratio := float(triangle_count(scaled.mesh)) / unscaled
	print("  triangles at scale 2 / scale 1: %.2f" % ratio)
	check(ratio > 0.75 and ratio < 1.33, "the tolerance is in world metres")


## Longest-edge bisection keeps the angles of the source: a plane's right triangles stay 45-45-90.
func test_angles() -> void:
	var field := Harness.make_stone_field(256, 40, 11)
	var baker := bake_with(plane(), uv_material(field, 0.05), {"max_triangles": 40000})
	var arrays := baker.mesh.surface_get_arrays(0)
	var rest: PackedFloat32Array = arrays[Mesh.ARRAY_CUSTOM0]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var smallest := 180.0
	for i in range(0, idx.size(), 3):
		var p: Array[Vector3] = []
		for k in 3:
			var j := idx[i + k] * 4
			p.append(Vector3(rest[j], rest[j + 1], rest[j + 2]))
		for k in 3:
			var e1 := p[(k + 1) % 3] - p[k]
			var e2 := p[(k + 2) % 3] - p[k]
			smallest = minf(smallest, rad_to_deg(e1.angle_to(e2)))
	print("  smallest angle %.2f deg over %d triangles" % [smallest, idx.size() / 3])
	check(smallest > 44.9, "no sliver triangles")


func test_attributes() -> void:
	var field := bump_field(256, 0.06)
	var baker := bake_with(plane(), uv_material(field, 0.08), {})
	var mesh := baker.mesh
	check((mesh.surface_get_format(0) & Mesh.ARRAY_FORMAT_CUSTOM0) != 0 and (mesh.surface_get_format(0) & Mesh.ARRAY_FORMAT_CUSTOM1) != 0, "the mesh carries CUSTOM0 and CUSTOM1")
	var a := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = a[Mesh.ARRAY_NORMAL]
	var t: PackedFloat32Array = a[Mesh.ARRAY_TANGENT]
	var c0: PackedFloat32Array = a[Mesh.ARRAY_CUSTOM0]
	var c1: PackedFloat32Array = a[Mesh.ARRAY_CUSTOM1]
	var flat_ok := true
	var tilt := 0.0
	var tangent_ok := true
	var rest_ok := true
	var levels_ok := true
	for i in v.size():
		var tangent := Vector3(t[i * 4], t[i * 4 + 1], t[i * 4 + 2])
		tangent_ok = tangent_ok and absf(tangent.dot(n[i])) < 0.02 and absf(absf(t[i * 4 + 3]) - 1.0) < 1e-6
		var r := Vector2(v[i].x, v[i].z).length()
		if r > 0.8:
			flat_ok = flat_ok and n[i].dot(Vector3.UP) > 0.9999 and tangent.dot(Vector3.RIGHT) > 0.999
		tilt = maxf(tilt, rad_to_deg(n[i].angle_to(Vector3.UP)))
		rest_ok = rest_ok and is_equal_approx(c0[i * 4], v[i].x) and is_equal_approx(c0[i * 4 + 2], v[i].z) and absf(c0[i * 4 + 1]) < 1e-6
		rest_ok = rest_ok and Vector3(c1[i * 4], c1[i * 4 + 1], c1[i * 4 + 2]).is_equal_approx(Vector3.UP)
		levels_ok = levels_ok and c1[i * 4 + 3] >= 0.0 and c1[i * 4 + 3] * 32.0 <= 24.0 and c0[i * 4 + 3] >= 0.0
	print("  normals tilt up to %.1f deg on the bump" % tilt)
	check(flat_ok, "far from the bump normals point up and tangents along +u")
	check(tilt > 20.0, "on the bump the normals follow the slope")
	check(tangent_ok, "tangents are perpendicular to the normals with a +-1 sign")
	check(rest_ok, "CUSTOM0 holds the rest position, CUSTOM1 the rest normal")
	check(levels_ok, "refinement levels and footprint mip levels are in range")


func test_lods() -> void:
	var field := bump_field(256, 0.06)
	var baker := bake_with(plane(), uv_material(field, 0.08), {"lods": true, "max_error": 0.0002})
	var surface := RenderingServer.mesh_get_surface(baker.mesh.get_rid(), 0)
	var lods: Array = surface.get("lods", [])
	print("  %d LODs for %d triangles" % [lods.size(), triangle_count(baker.mesh)])
	check(lods.size() >= 2, "the baked mesh has LODs")
	var plain := bake_with(plane(), uv_material(field, 0.08), {"lods": false, "max_error": 0.0002})
	check(baker.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] == plain.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX], "LODs share the full mesh's vertices")


func test_cancel() -> void:
	var field := Harness.make_stone_field(512, 200, 13)
	var materials: Array[Material] = [uv_material(field, 0.05)]
	var baker := GADSMeshBaker.new()
	baker.setup(plane(), materials, Transform3D.IDENTITY, {"max_error": 0.00001, "max_triangles": 5000000, "lods": false})
	var started := Time.get_ticks_msec()
	check(baker.start(), "a background bake starts")
	baker.cancel()
	var ok := baker.finish()
	var ms := Time.get_ticks_msec() - started
	print("  cancelled after %d ms" % ms)
	check(not ok and baker.error == "cancelled" and baker.mesh == null, "cancel stops the bake without a result")
	check(ms < 2000, "cancel takes effect promptly")


func _make_node(material: Material) -> GADSMeshInstance3D:
	var node := GADSMeshInstance3D.new()
	node.name = "Baked"
	node.source_mesh = plane()
	node.material_override = material
	node.cache_directory = CACHE_DIR
	node.quality = GADSMeshInstance3D.Quality.LOW
	return node


func test_node() -> void:
	var field := bump_field(128, 0.08)
	var node := _make_node(uv_material(field, 0.05))
	root.add_child(node)
	var source := node.source_mesh
	check(node.mesh == source and not node.baked, "an unbaked node draws its source mesh")
	var progress := []
	node.bake_progress.connect(func(p: float, _t: int) -> void: progress.append(p))
	var finished := []
	node.bake_finished.connect(func(ok: bool) -> void: finished.append(ok))
	check(node.bake_async() == OK and node.is_baking(), "a background bake starts")
	check(node.bake_async() == ERR_BUSY, "a second bake waits for the first")
	while node.is_baking():
		await process_frame
	check(finished == [true] and node.baked and node.mesh != source and node.mesh is ArrayMesh, "it finishes with the baked mesh shown")
	check(node.get_instance_shader_parameter(&"gads_baked") == 1.0, "the materials are told the mesh is baked")
	var path: String = node.bake_stats.get("path", "")
	check(path.begins_with(CACHE_DIR) and FileAccess.file_exists(path) and node.mesh.resource_path == path, "the bake is a cache file the scene refers to (%s)" % path)
	print("  %s" % node.get_bake_summary().replace("\n", " | "))
	var first := node.mesh
	node.clear_bake()
	# The parameter is removed, so it reads back as the shader's default (null on the headless
	# dummy renderer, which does not know shader defaults).
	check(not node.baked and node.mesh == source and node.get_instance_shader_parameter(&"gads_baked") in [0.0, null], "Clear shows the source mesh again")
	var t0 := Time.get_ticks_msec()
	check(node.bake() == OK and node.bake_stats.get("cached", false) and node.mesh == first, "baking the same inputs again takes the cached file (%d ms)" % (Time.get_ticks_msec() - t0))
	check(node.bake(true) == OK and not node.bake_stats.get("cached", false), "Rebuild ignores the cache")
	check(source == node.source_mesh and (source as PlaneMesh).size == Vector2(2, 2), "the source mesh is untouched")
	node.queue_free()
	await process_frame


func test_staleness() -> void:
	var field := bump_field(128, 0.08)
	var mat := uv_material(field, 0.05)
	var node := _make_node(mat)
	root.add_child(node)
	node.bake()
	check(not node.is_bake_stale(), "fresh after the bake")
	node.position = Vector3(3, 0, 1)
	check(not node.is_bake_stale(), "moving a UV-mapped mesh keeps the bake")
	node.scale = Vector3(2, 2, 2)
	check(node.is_bake_stale(), "scaling it does not (the tolerance is in metres)")
	node.scale = Vector3.ONE
	mat.set_shader_parameter("height_m", 0.06)
	check(node.is_bake_stale(), "a new relief depth makes it stale")
	mat.set_shader_parameter("height_m", 0.05)
	node.quality = GADSMeshInstance3D.Quality.HIGH
	check(node.is_bake_stale(), "a new quality makes it stale")
	node.quality = GADSMeshInstance3D.Quality.LOW
	(node.source_mesh as PlaneMesh).subdivide_width = 3
	check(node.is_bake_stale(), "an edited source mesh makes it stale")
	node.queue_free()
	var world := GADSMaterials.create(GADSMaterials.Mapping.WORLD, {"height": ImageTexture.create_from_image(field["image"])}, {"height_m": 0.05, "height_center": 0.0}, GADSMaterials.Quality.POM)
	var planar := _make_node(world)
	root.add_child(planar)
	planar.bake()
	planar.position = Vector3(0.3, 0, 0)
	check(planar.is_bake_stale(), "moving a world-mapped mesh makes it stale")
	check(not planar._get_configuration_warnings().is_empty(), "the node warns about a stale bake")
	planar.queue_free()
	await process_frame


func test_collision() -> void:
	var field := bump_field(128, 0.1)
	var node := _make_node(uv_material(field, 0.2))
	node.collision = GADSMeshBaker.Collision.TRIMESH
	node.collision_max_triangles = 2000
	root.add_child(node)
	check(node.bake() == OK, "a bake with collision")
	var bodies := node.get_children(true).filter(func(c: Node) -> bool: return c is StaticBody3D)
	check(bodies.size() == 1 and node.get_child_count(false) == 0, "an internal static body (not part of the scene)")
	var shape := node.collision_shape as ConcavePolygonShape3D
	var tris := shape.get_faces().size() / 3 if shape != null else 0
	print("  collision %d triangles, render %d" % [tris, node.bake_stats.get("triangles", 0)])
	check(shape != null and tris <= 2000 and tris < int(node.bake_stats["triangles"]), "the collision shape has its own, lower resolution")
	await physics_frame
	await physics_frame
	var space := node.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(0, 1, 0), Vector3(0, -1, 0)))
	var hit_y: float = hit["position"].y if not hit.is_empty() else -1.0
	print("  a ray down the bump's centre hits at %.1f mm (relief top 200 mm)" % (hit_y * 1000.0))
	check(absf(hit_y - 0.2) < 0.01, "the shape follows the relief")
	node.collision = GADSMeshBaker.Collision.NONE
	check(node.get_children(true).filter(func(c: Node) -> bool: return c is StaticBody3D and not c.is_queued_for_deletion()).is_empty(), "collision NONE removes the body")
	node.queue_free()
	await process_frame


func test_save_load() -> void:
	var field := bump_field(64, 0.08)
	var node := _make_node(uv_material(field, 0.05))
	root.add_child(node)
	node.bake()
	var baked_path := node.mesh.resource_path
	var packed := PackedScene.new()
	check(packed.pack(node) == OK, "the node packs")
	var scene_path := CACHE_DIR.path_join("scene.tscn")
	check(ResourceSaver.save(packed, scene_path) == OK, "the scene saves")
	node.queue_free()
	await process_frame
	var text := FileAccess.get_file_as_string(scene_path)
	check(text.contains('path="%s"' % baked_path) and not text.contains("GADSCollision"), "the scene refers to the baked file and holds no collision node")
	var copy := (ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate() as GADSMeshInstance3D
	root.add_child(copy)
	check(copy.baked and copy.mesh != null and copy.mesh.resource_path == baked_path, "the loaded node shows the baked mesh")
	check(copy.source_mesh is PlaneMesh and copy.get_instance_shader_parameter(&"gads_baked") == 1.0, "with its source mesh and the baked flag for the materials")
	check(not copy.is_bake_stale(), "and the bake is still current")
	copy.queue_free()
	await process_frame


## GADSProfiler: totals, per-object statistics, recommendations and their fixes, a target.
func test_profiler() -> void:
	var field := bump_field(256, 0.05)
	var scene := Node3D.new()
	root.add_child(scene)
	var manager := GADSManager.new()
	scene.add_child(manager)
	var dense := _make_node(uv_material(field, 0.06))
	dense.name = "Dense"
	dense.quality = GADSMeshInstance3D.Quality.ULTRA
	scene.add_child(dense)
	dense.bake()
	var unbaked := _make_node(uv_material(field, 0.06))
	unbaked.name = "Unbaked"
	scene.add_child(unbaked)
	var pom := MeshInstance3D.new()
	pom.mesh = plane()
	pom.material_override = uv_material(field, 0.03)
	scene.add_child(pom)
	var cam := Camera3D.new()
	scene.add_child(cam)
	cam.look_at_from_position(Vector3(0, 60, 60), Vector3.ZERO)
	await process_frame
	# Small thresholds, so a quick bake counts as dense.
	GADSProfiler.dense_triangles = 1000
	GADSProfiler.range_triangles = 500
	var report := GADSProfiler.collect(scene, cam)
	var t: Dictionary = report["totals"]
	var dense_stats: Dictionary = report["objects"].filter(func(o: Dictionary) -> bool: return o["name"] == "Dense")[0]
	print("  totals %s; Dense covers %.2f %% with %d triangles" % [t, dense_stats["coverage"] * 100.0, dense_stats["triangles"]])
	check(t["objects"] == 2 and dense_stats["triangles"] == dense.bake_stats["triangles"] and dense_stats["base_triangles"] == 2,
			"per-object triangles: baked and source")
	check(t["generated_triangles"] == dense_stats["triangles"] - 2 and t["base_triangles"] == 4, "totals add up (generated = baked - source)")
	check(report["surfaces"] >= 1 and dense_stats["memory_bytes"] > 0 and t["cache_bytes"] > 0, "parallax surfaces, memory and cache size are counted")
	check(dense_stats["coverage"] > 0.0 and dense_stats["coverage"] < 0.05, "screen coverage of a distant mesh is small")
	var messages := "\n".join(report["recommendations"].map(func(r: Dictionary) -> String: return r["message"]))
	check(messages.contains("Unbaked is not baked") and messages.contains("Dense uses"), "it recommends baking the unbaked mesh and a range for the dense one")
	var range_fix: Dictionary = report["recommendations"].filter(func(r: Dictionary) -> bool: return r["object"] == dense)[0]["fix"]
	GADSProfiler.apply_fixes([range_fix])
	check(dense.geometry_range > 10.0 and dense.get_fallback() != null, "the fix sets geometry_range (%.1f m)" % dense.geometry_range)
	var maps: Array = report["height_maps"]
	check(maps.size() == 3 and maps[0]["useful_size"] <= maps[0]["size"], "each height map is analysed once (three textures here)")
	var fixes := GADSProfiler.optimize_for(GADSProfiler.Target.HANDHELD, scene)
	GADSProfiler.apply_fixes(fixes)
	check(manager.preset == GADSSettings.Preset.LOW and is_equal_approx(dense.geometry_range, snappedf(dense.suggest_geometry_range(3.0), 0.1)),
			"Optimize for Handheld sets the Low preset and a range for three pixels of relief")
	check(not dense.is_bake_stale(), "optimizing changes settings only (the bake stays current)")
	GADSProfiler.dense_triangles = 200000
	GADSProfiler.range_triangles = 50000
	var overlay := GADSStatsOverlay.new()
	overlay.target = overlay.get_path_to(scene) if overlay.is_inside_tree() else NodePath()
	scene.add_child(overlay)
	overlay.target = overlay.get_path_to(scene)
	overlay._refresh()
	check(overlay.get_report().get("totals", {}).get("objects", 0) == 2, "the stats overlay profiles its target")
	scene.queue_free()
	await process_frame


## Silhouette POM: a sphere with stones carved into it (height_center 1) shows them in its outline
## like the baked sphere does; plain parallax keeps the smooth outline.
func test_silhouette() -> void:
	var stones := Harness.make_stone_field(256, 30, 3)
	var params := {"height_m": 0.08, "height_center": 1.0, "uv_scale": Vector2(4, 2)}
	var textures := {"height": ImageTexture.create_from_image(stones["image"])}
	var s := h.new_lit_scene(Color(0.6, 0.6, 0.6))
	h.add_camera(Vector3(0, 0, 2.2), Vector3.ZERO, 40.0)
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 96
	sphere.rings = 48
	var mi := MeshInstance3D.new()
	mi.mesh = sphere
	mi.material_override = GADSMaterials.create(GADSMaterials.Mapping.UV, textures, params, GADSMaterials.Quality.POM)
	s.add_child(mi)
	await h.frames(4)
	var plain := await h.capture()
	var sil_mat := GADSMaterials.create(GADSMaterials.Mapping.UV, textures, params, GADSMaterials.Quality.POM)
	GADSMaterials.set_silhouette(sil_mat, true)
	mi.material_override = sil_mat
	await h.frames(4)
	var carved := await h.capture()
	mi.queue_free()
	var node := _make_node(GADSMaterials.create(GADSMaterials.Mapping.UV, textures, params, GADSMaterials.Quality.POM))
	node.source_mesh = sphere
	node.quality = GADSMeshInstance3D.Quality.HIGH
	s.add_child(node)
	node.bake()
	await h.frames(4)
	var baked := await h.capture()
	node.queue_free()
	var plain_off := 0
	var carved_off := 0
	var outline := 0
	for y in SIZE.y:
		for x in SIZE.x:
			var b := baked.get_pixel(x, y).get_luminance() > 0.002
			var p := plain.get_pixel(x, y).get_luminance() > 0.002
			var c := carved.get_pixel(x, y).get_luminance() > 0.002
			if p and not b:
				outline += 1
			plain_off += 1 if p != b else 0
			carved_off += 1 if c != b else 0
	print("  pixels whose coverage differs from the baked sphere: plain parallax %d, silhouette parallax %d (the smooth outline covers %d the baked one does not)" % [plain_off, carved_off, outline])
	check(outline > 300, "the carved relief shows in the baked sphere's outline")
	check(carved_off < plain_off * 0.6, "silhouette parallax draws the outline like the baked mesh, plain parallax does not")


## A baked mesh lit like the parallax version of the same material (with a normal map that matches
## the height map) looks the same: textures are mapped at the rest position and the normal map
## adds only the detail finer than the triangles. Applying the full normal map on top of the
## geometry's own slope would tilt the flanks twice.
func test_render() -> void:
	var field := bump_field(256, 0.07)
	var amp := 0.12
	var normal := normal_map_of(field, 2.0, amp)
	var params := {"height_m": amp, "height_center": 0.0}
	var textures := {"height": ImageTexture.create_from_image(field["image"]), "normal": normal}
	var s := h.new_lit_scene(Color(0.15, 0.15, 0.15))
	h.add_sun(35.0, 30.0, false)
	h.add_camera(Vector3(0, 2.2, 1.6), Vector3(0, 0, 0), 50.0)
	var pom_mat := GADSMaterials.create(GADSMaterials.Mapping.UV, textures, params, GADSMaterials.Quality.POM)
	var mi := MeshInstance3D.new()
	mi.mesh = plane()
	mi.material_override = pom_mat
	s.add_child(mi)
	await h.frames(4)
	var pom := await h.capture()
	mi.queue_free()
	var node := _make_node(GADSMaterials.create(GADSMaterials.Mapping.UV, textures, params, GADSMaterials.Quality.POM))
	node.quality = GADSMeshInstance3D.Quality.HIGH
	s.add_child(node)
	node.bake()
	await h.frames(4)
	var baked := await h.capture()
	# The same, but with the full normal map applied on the geometry (what the shader must not do).
	node.set_instance_shader_parameter(&"gads_baked", 0.0)
	var naive_mat := GADSMaterials.create(GADSMaterials.Mapping.UV, textures, {"height_m": 0.0}, GADSMaterials.Quality.FLAT)
	node.material_override = naive_mat
	await h.frames(4)
	var naive := await h.capture()
	# Compared where the relief shows: the pixels where parallax differs from the flat plane.
	node.material_override = GADSMaterials.create(GADSMaterials.Mapping.UV, {}, {"height_m": 0.0}, GADSMaterials.Quality.FLAT)
	node.mesh = node.source_mesh
	await h.frames(4)
	var flat := await h.capture()
	node.mesh = load(node.bake_stats["path"])
	var mask := []
	for y in range(0, SIZE.y, 2):
		for x in range(0, SIZE.x, 2):
			if _difference(pom.get_pixel(x, y), flat.get_pixel(x, y)) > 0.02:
				mask.append(Vector2i(x, y))
	var d_baked := _mean_difference(pom, baked, mask)
	var d_naive := _mean_difference(pom, naive, mask)
	print("  on the %d pixels where the relief shows, mean difference to parallax: baked %.4f, normal map on top of the geometry %.4f" % [mask.size(), d_baked, d_naive])
	check(mask.size() > 1000, "the relief covers enough of the image to compare")
	check(d_baked < 0.02, "the baked mesh renders like the parallax material")
	check(d_naive > 2.0 * d_baked, "the normal map is not applied on top of the geometry's slope")
	# The baked mesh skips the march: the cost view shows steps only without the baked flag.
	node.material_override = GADSMaterials.create(GADSMaterials.Mapping.UV, textures, params, GADSMaterials.Quality.POM)
	GADSGlobals.set_value(GADSGlobals.POM_STEPS, Vector4(8, 24, 3, 0))
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(GADSManager.DebugView.COST, 0.1, 0, 0))
	var steps := []
	for flag in [0.0, 1.0]:
		node.set_instance_shader_parameter(&"gads_baked", flag)
		await h.frames(3)
		var cost := await h.capture()
		var most := 0.0
		for y in range(0, SIZE.y, 4):
			for x in range(0, SIZE.x, 4):
				most = maxf(most, cost.get_pixel(x, y).r)
		steps.append(most * 64.0)
	print("  most parallax steps per pixel: %.0f without the baked flag, %.0f with it" % steps)
	check(steps[0] > 0.0 and steps[1] == 0.0, "a baked mesh marches no parallax steps")
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(GADSManager.DebugView.TESSELLATION, 0.1, 0, 0))
	await h.frames(3)
	var tess := await h.capture()
	var centre := tess.get_pixel(SIZE.x / 2, SIZE.y / 2)
	var edge := tess.get_pixel(SIZE.x / 2, int(SIZE.y * 0.85)) # 0.9 m from the bump, on the plane
	print("  tessellation view: centre %s, near edge %s" % [centre, edge])
	check(centre.r > centre.b and edge.b > edge.r, "the tessellation view shows the dense bump warm and the flat plane cold")
	node.queue_free()
	await process_frame


static func _difference(a: Color, b: Color) -> float:
	return (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0


static func _mean_difference(a: Image, b: Image, pixels: Array) -> float:
	var sum := 0.0
	for p: Vector2i in pixels:
		sum += _difference(a.get_pixelv(p), b.get_pixelv(p))
	return sum / maxf(pixels.size(), 1.0)


## Beyond geometry_range the source mesh with parallax replaces the baked geometry: the
## Tessellation view shows the baked bump's refinement near and none (blue) far away, through a
## telephoto lens so the plane fills the view at every distance.
func test_geometry_range() -> void:
	var field := bump_field(128, 0.1)
	var s := h.new_debug_scene()
	var node := _make_node(uv_material(field, 0.08))
	node.quality = GADSMeshInstance3D.Quality.HIGH
	s.add_child(node)
	node.bake()
	node.geometry_range = 12.0
	node.geometry_range_margin = 1.0
	var fallback := node.get_fallback()
	check(fallback != null and fallback.mesh == node.source_mesh and node.get_child_count(false) == 0,
			"an internal child draws the source mesh beyond the range")
	var suggested := node.suggest_geometry_range()
	print("  suggested range for an 80 mm relief at 1080p, 70 degrees: %.1f m" % suggested)
	check(suggested > 30.0 and suggested < 60.0, "suggest_geometry_range() is where the relief covers about two pixels")
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(GADSManager.DebugView.TESSELLATION, 0.1, 0, 0))
	var cam := h.add_camera(Vector3(0, 1, 1), Vector3.ZERO, 6.0)
	var colors := {}
	for distance in [6.0, 20.0]:
		cam.look_at_from_position(Vector3(0, 1, 1).normalized() * distance, Vector3.ZERO)
		await h.frames(4)
		var img := await h.capture()
		colors[distance] = img.get_pixel(SIZE.x / 2, SIZE.y / 2)
	print("  centre at 6 m %s, at 20 m %s" % [colors[6.0], colors[20.0]])
	check(colors[6.0].r > colors[6.0].b, "near: the baked geometry (refined, warm)")
	check(colors[20.0].b > 0.9 and colors[20.0].r < 0.2, "far: the source mesh with parallax (no refinement, blue)")
	node.geometry_range = 0.0
	await process_frame
	check(node.get_fallback() == null and node.visibility_range_end == 0.0, "geometry_range 0 removes the fallback and the node's range")
	node.queue_free()
	await process_frame


## A GADSMeshInstance3D with view_dependent re-tessellates in the background as the camera moves.
func test_runtime_tessellation() -> void:
	var s := h.new_debug_scene()
	var field := Harness.make_stone_field(256, 60, 11)
	var node := _make_node(uv_material(field, 0.05))
	node.source_mesh = plane(8.0)
	node.view_dependent = true
	node.view_max_triangles = 400000
	s.add_child(node)
	var cam := h.add_camera(Vector3(-3.5, 0.6, -3.5), Vector3(0, 0, 0))
	var done := []
	node.view_tessellated.connect(func(stats: Dictionary) -> void: done.append(stats))
	var waited := 0
	while done.is_empty() and waited < 600:
		await process_frame
		waited += 1
	check(done.size() == 1 and node.mesh is ArrayMesh and node.mesh != node.source_mesh, "the first runtime mesh replaces the source")
	check(node.get_instance_shader_parameter(&"gads_baked") == 1.0, "the materials are told the mesh is baked")
	var near_triangles: int = done[0]["triangles"] if not done.is_empty() else 0
	await h.frames(5)
	check(done.size() == 1 and not node.is_view_tessellating(), "a still camera does not tessellate again")
	cam.global_position = Vector3(0, 30, 30)
	waited = 0
	while done.size() < 2 and waited < 600:
		await process_frame
		waited += 1
	var far_triangles: int = done[1]["triangles"] if done.size() > 1 else 0
	print("  near %d triangles, far %d" % [near_triangles, far_triangles])
	check(done.size() == 2 and far_triangles * 4 < near_triangles, "moving away tessellates again, coarser")
	check(not node.baked and node.bake_key.is_empty(), "the runtime meshes are not a bake (nothing saved)")
	node.view_dependent = false
	check(node.mesh == node.source_mesh and node.get_instance_shader_parameter(&"gads_baked") in [0.0, null], "turning it off shows the source mesh again")
	h.clear_scene()
	await process_frame


## The scene import options (GADSImportTools.process, what the import plugin runs): height-mapped
## materials become GADS materials, "*-gads" meshes become baked GADSMeshInstance3D nodes.
func test_import() -> void:
	var field := bump_field(128, 0.08)
	var height := ImageTexture.create_from_image(field["image"])
	var scene := Node3D.new()
	scene.name = "Imported"
	var group := Node3D.new()
	group.name = "Props"
	group.scale = Vector3(2, 2, 2)
	scene.add_child(group)
	group.owner = scene
	var std := StandardMaterial3D.new()
	std.heightmap_enabled = true
	std.heightmap_texture = height
	std.heightmap_scale = 5.0
	var rock := MeshInstance3D.new()
	rock.name = "Rock-gads"
	rock.mesh = plane()
	rock.material_override = std
	rock.position = Vector3(1, 0, 0)
	group.add_child(rock)
	rock.owner = scene
	var child := Node3D.new()
	child.name = "Marker"
	rock.add_child(child)
	child.owner = scene
	var plain := MeshInstance3D.new()
	plain.name = "Floor"
	plain.mesh = plane()
	plain.material_override = std
	scene.add_child(plain)
	plain.owner = scene
	var report := GADSImportTools.process(scene, {"convert_materials": true, "metres_per_repeat": 1.0, "quality": GADSMeshInstance3D.Quality.DRAFT})
	print("  %s" % report)
	var node := scene.get_node_or_null("Props/Rock") as GADSMeshInstance3D
	check(node != null and node.position == Vector3(1, 0, 0) and node.get_node_or_null("Marker") != null and node.owner == scene
		and node.get_node("Marker").owner == scene, "a mesh named *-gads becomes a GADSMeshInstance3D (suffix gone, children and place kept)")
	check(GADSMaterials.is_gads_material(node.material_override) and GADSMaterials.is_gads_material(plain.material_override)
		and is_equal_approx(node.material_override.get_shader_parameter("height_m"), 0.05), "height-mapped materials became GADS materials")
	check(report["converted"] == 1 and report["meshes"] == 1 and report["baked"] == 1 and node.baked and node.mesh is ArrayMesh
		and node.mesh.resource_path.is_empty(), "it is baked into the scene (no cache file)")
	check(scene.get_node_or_null("Floor") is MeshInstance3D and not (scene.get_node("Floor") is GADSMeshInstance3D), "other meshes stay as they are")
	# The bake used the transform relative to the scene's root (scale 2): the relief stays 5 cm in the world.
	var v: PackedVector3Array = node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var bottom := INF
	for p in v:
		bottom = minf(bottom, p.y)
	# height_center 1: the relief goes down to -height_m (5 cm) where the bump map is 0.
	check(absf(bottom * 2.0 + 0.05) < 0.003, "the bake follows the scene's scale (lowest %.4f m in object space, x 2)" % bottom)
	var packed := PackedScene.new()
	check(packed.pack(scene) == OK, "the processed scene packs (what the importer saves)")
	var again := packed.instantiate()
	var reloaded := again.get_node("Props/Rock") as GADSMeshInstance3D
	check(reloaded.baked and reloaded.mesh is ArrayMesh, "an instance of it shows the bake")
	again.free()
	report = GADSImportTools.process(scene, {"meshes": GADSImportTools.Meshes.ALL_GADS, "bake": false})
	check(report["meshes"] == 1 and scene.get_node("Floor") is GADSMeshInstance3D and not (scene.get_node("Floor") as GADSMeshInstance3D).baked,
		"Every Mesh With a GADS Material picks the rest (unbaked when bake is off)")
	scene.free()


## A clustered bake: the same triangles as the whole bake, split into compact clusters of at most
## cluster_triangles, each with its own LODs.
func test_clusters() -> void:
	var field := Harness.make_stone_field(256, 60, 11)
	var mat := uv_material(field, 0.05)
	var m := plane(8.0)
	var whole := bake_with(m, mat, {"max_error": 0.001})
	var split := bake_with(m, mat, {"max_error": 0.001, "cluster_triangles": 4000, "lods": true})
	var meshes: Array = [split.mesh] + GADSMeshInstance3D.cluster_meshes_of(split.mesh)
	var counts: Array[int] = []
	var total := 0
	var area := 0.0
	var lods := true
	for cm: Mesh in meshes:
		var n := triangle_count(cm)
		counts.append(n)
		total += n
		var box := cm.get_aabb()
		area += box.size.x * box.size.z
		lods = lods and not (RenderingServer.mesh_get_surface(cm.get_rid(), 0).get("lods", []) as Array).is_empty()
	print("  %d triangles whole, %d in %d clusters (%d to %d each); cluster boxes cover %.1f m2 of 64" % [
		triangle_count(whole.mesh), total, meshes.size(), counts.min(), counts.max(), area])
	check(meshes.size() == split.stats.get("clusters", 0) and meshes.size() >= 8 and counts.max() <= 4000 and counts.min() >= 1500,
		"clusters of 2 000 to 4 000 triangles")
	check(total == triangle_count(whole.mesh), "together they hold every triangle")
	# The same triangles (as position triples, in any order): splitting adds no cracks.
	var key := func(mesh: Mesh) -> Dictionary:
		var out := {}
		for t: Array in triangles_of(mesh):
			out[str([(t[0] as Vector3).snapped(Vector3.ONE * 1e-5), (t[1] as Vector3).snapped(Vector3.ONE * 1e-5), (t[2] as Vector3).snapped(Vector3.ONE * 1e-5)])] = true
		return out
	var a: Dictionary = key.call(whole.mesh)
	var b := {}
	for cm: Mesh in meshes:
		b.merge(key.call(cm))
	check(a.size() == b.size() and a.keys().all(func(k: String) -> bool: return b.has(k)), "the same triangles as the whole bake")
	check(area < 64.0 * 1.25, "clusters are compact (their boxes overlap little)")
	check(lods, "each cluster has its own LODs")


## A GADSMeshInstance3D with cluster_triangles draws its clusters as internal instances that follow
## its settings, and the parallax fallback switches them all at once by one distance.
func test_cluster_node() -> void:
	var field := bump_field(128, 0.1)
	var s := h.new_debug_scene()
	var node := _make_node(uv_material(field, 0.08))
	node.quality = GADSMeshInstance3D.Quality.HIGH
	node.cluster_triangles = 300
	s.add_child(node)
	check(node.bake() == OK and node.baked, "a clustered bake")
	check(GADSProfiler.mesh_triangles(node.mesh) == int(node.bake_stats.get("triangles", -1)), "the profiler counts every cluster's triangles")
	var children := node.get_cluster_nodes()
	print("  %d instances" % node.get_cluster_count())
	check(node.get_cluster_count() >= 4 and children.size() == node.get_cluster_count() - 1 and not node.get_children().has(children[0])
		and node.get_children(true).has(children[0]), "the other clusters are internal children")
	check(children.all(func(c: MeshInstance3D) -> bool: return c.get_instance_shader_parameter(&"gads_baked") == 1.0 and c.material_override == node.material_override),
		"they draw with the node's materials, as baked meshes")
	var other := uv_material(field, 0.02)
	node.material_override = other
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	await process_frame
	check(children.all(func(c: MeshInstance3D) -> bool: return c.material_override == other and c.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF),
		"they follow the node's material and shadow settings")
	node.material_override = uv_material(field, 0.08)
	node.geometry_range = 12.0
	node.geometry_range_margin = 1.0
	await process_frame
	check(node.get_fallback() != null and node.get_fallback_dependents().size() == node.get_cluster_count() and node.visibility_range_end == 0.0,
		"with a geometry range all clusters depend on the fallback's distance (one switch for all)")
	if DisplayServer.get_name() != "headless":
		GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(GADSManager.DebugView.TESSELLATION, 0.1, 0, 0))
		var cam := h.add_camera(Vector3(0, 1, 1), Vector3.ZERO, 6.0)
		var colors := {}
		for distance in [6.0, 20.0]:
			cam.look_at_from_position(Vector3(0, 1, 1).normalized() * distance, Vector3.ZERO)
			await h.frames(4)
			var img := await h.capture()
			colors[distance] = img.get_pixel(SIZE.x / 2, SIZE.y / 2)
		print("  centre at 6 m %s, at 20 m %s" % [colors[6.0], colors[20.0]])
		check(colors[6.0].r > colors[6.0].b and colors[20.0].b > 0.9 and colors[20.0].r < 0.2,
			"near the clustered geometry (refined), far the source mesh with parallax")
		GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(0, 0.1, 0, 0))
	node.geometry_range = 0.0
	await process_frame
	check(node.get_fallback_dependents().is_empty(), "range 0 lets them go")
	node.clear_bake()
	await process_frame
	check(node.get_cluster_nodes().is_empty() and node.mesh == node.source_mesh, "Clear removes the clusters")
	node.queue_free()
	await process_frame


## The node's Diagnose overlay: the source mesh's edges as lines in an internal child.
func test_diagnostics() -> void:
	var node := _make_node(uv_material(bump_field(64, 0.1), 0.05))
	node.source_mesh = BoxMesh.new()
	root.add_child(node)
	var report := node.diagnose()
	check(report["counts"]["open"] == 0 and report["counts"]["uv_seam"] + report["counts"]["hard"] == 12, "diagnose() reports the source mesh's edges")
	node.set_diagnostics_visible(true)
	var overlay := node.get_children(true).filter(func(c: Node) -> bool: return c.name == "GADSDiagnostics")
	var lines: Mesh = (overlay[0] as MeshInstance3D).mesh if overlay.size() == 1 else null
	var count := (lines.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() if lines != null and lines.get_surface_count() == 1 else 0
	check(overlay.size() == 1 and not node.get_children().has(overlay[0]) and count == 24, "the overlay is an internal child drawing each edge as a line (%d vertices)" % count)
	node.set_diagnostics_visible(false)
	await process_frame
	check(not node.is_diagnostics_visible() and node.get_children(true).filter(func(c: Node) -> bool: return c.name == "GADSDiagnostics").is_empty(),
		"and goes away")
	node.queue_free()
	await process_frame


## An RGBF vector displacement map: coefs (the x, y and z offsets per unit of field) times field.
static func vector_map_of(field: Dictionary, coefs: Vector3) -> ImageTexture:
	var size: int = field["size"]
	var data: PackedFloat32Array = field["data"]
	var rgb := PackedFloat32Array()
	rgb.resize(size * size * 3)
	for i in size * size:
		rgb[i * 3] = coefs.x * data[i]
		rgb[i * 3 + 1] = coefs.y * data[i]
		rgb[i * 3 + 2] = coefs.z * data[i]
	return ImageTexture.create_from_image(Image.create_from_data(size, size, false, Image.FORMAT_RGBF, rgb.to_byte_array()))


## A vector-displaced material (no height map) with the vector map vec, scale m metres.
func vector_material(vec: Texture2D, m: float, params := {}) -> ShaderMaterial:
	var p := {"vector_displacement_texture": vec, "vector_displacement_m": m, "vector_displacement_signed": true}
	p.merge(params, true)
	return GADSMaterials.create(GADSMaterials.Mapping.UV, {}, p, GADSMaterials.Quality.POM)


## The position on the flat source mesh's first triangle's plane at uv, and the tangent frame the
## bake uses there: [rest(uv) callable, x (+u), y (the texture's up, -v), z (normal)].
static func _uv_frame(mesh: Mesh) -> Array:
	var arrays := mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var p0 := v[idx[0]]
	var e1 := v[idx[1]] - p0
	var e2 := v[idx[2]] - p0
	var d1 := uv[idx[1]] - uv[idx[0]]
	var d2 := uv[idx[2]] - uv[idx[0]]
	var det := d1.x * d2.y - d1.y * d2.x
	var dpdu := (e1 * d2.y - e2 * d1.y) / det
	var dpdv := (e2 * d1.x - e1 * d2.x) / det
	var uv0 := uv[idx[0]]
	var rest := func(t: Vector2) -> Vector3: return p0 + dpdu * (t.x - uv0.x) + dpdv * (t.y - uv0.y)
	var n := (arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array)[idx[0]].normalized()
	var x := dpdu.normalized()
	var y := (-dpdv).normalized()
	return [rest, x, y, n]


## Vector displacement (a vector map, UV mapping): vertices move by the map's XYZ in the surface's
## tangent frame (or in object space), refinement follows lateral relief as well as height, seams
## stay closed, and a material whose vector map is off bakes as before.
func test_vector_displacement() -> void:
	var field := bump_field(256, 0.1)
	var m := 0.05
	var tolerance := 0.0005
	# Tangent space, signed: x 0.5, y -0.3, z 1 per unit of the bump.
	var coefs := Vector3(0.5, -0.3, 1.0)
	var mesh := plane()
	var baker := bake_with(mesh, vector_material(vector_map_of(field, coefs), m), {"max_error": tolerance})
	check(baker.mesh != null, "a plane with a vector map and no height map bakes (%s)" % baker.error)
	if baker.mesh == null:
		return
	var frame := _uv_frame(mesh)
	var rest: Callable = frame[0]
	var expect := func(t: Vector2) -> Vector3:
		return rest.call(t) + ((frame[1] as Vector3) * coefs.x + (frame[2] as Vector3) * coefs.y + (frame[3] as Vector3) * coefs.z) * m * Harness.sample_field(field, t)
	var arrays := baker.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var worst_vertex := 0.0
	var peak := 0.0
	for i in v.size():
		worst_vertex = maxf(worst_vertex, v[i].distance_to(expect.call(uv[i])))
		peak = maxf(peak, v[i].distance_to(rest.call(uv[i])))
	var worst := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in range(0, idx.size(), 3):
		var a := rng.randf()
		var b := rng.randf() * (1.0 - a)
		var c := 1.0 - a - b
		var p := v[idx[i]] * a + v[idx[i + 1]] * b + v[idx[i + 2]] * c
		var t := uv[idx[i]] * a + uv[idx[i + 1]] * b + uv[idx[i + 2]] * c
		worst = maxf(worst, p.distance_to(expect.call(t)))
	print("  %d triangles; vertices within %.3f mm of rest + frame * map, points inside the triangles within %.3f mm (tolerance %.1f mm)" % [
		idx.size() / 3, worst_vertex * 1000.0, worst * 1000.0, tolerance * 1000.0])
	check(worst_vertex < tolerance and peak > 0.95 * m * coefs.length(),
		"vertices move by the map's vector in the tangent frame (x +u, y the texture's up, z the normal; the peak by %.1f mm)" % (peak * 1000.0))
	check(worst < 2.0 * tolerance, "and the surface stays within twice the tolerance of the displaced field")
	# A purely sideways bump refines as a height bump does: where it is.
	var lateral := bake_with(mesh, vector_material(vector_map_of(field, Vector3(1.0, 0.0, 0.0)), m), {"max_error": tolerance})
	var near := 0
	var far := 0
	for tri: Array in triangles_of(lateral.mesh):
		var centre: Vector3 = (tri[0] + tri[1] + tri[2]) / 3.0
		var r := Vector2(centre.x, centre.z).length()
		if r < 0.4:
			near += 1
		elif r > 0.8:
			far += 1
	var density_near := near / (PI * 0.16)
	var density_far := far / (4.0 - PI * 0.64)
	print("  sideways bump: %d triangles, density ratio near / far %.0f" % [triangle_count(lateral.mesh), density_near / maxf(density_far, 1e-6)])
	check(density_near > 10.0 * density_far, "a sideways bump (no height change) refines where it is")
	var heights := 0.0
	for p in (lateral.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array):
		heights = maxf(heights, absf(p.y))
	check(heights < 1e-6, "and moves nothing off the plane")
	# Unsigned: 0.5 is no offset.
	var grey := Image.create(16, 16, false, Image.FORMAT_RGB8)
	grey.fill(Color8(128, 128, 128))
	var flat := bake_with(mesh, vector_material(ImageTexture.create_from_image(grey), m, {"vector_displacement_signed": false}), {"max_error": tolerance})
	var moved := 0.0
	for p in (flat.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array):
		moved = maxf(moved, absf(p.y))
	check(flat.mesh != null and triangle_count(flat.mesh) == 2 and moved < m * 0.01, "unsigned maps are centred on 0.5 (grey moves nothing: %d triangles, %.2f mm)" % [
		triangle_count(flat.mesh) if flat.mesh != null else 0, moved * 1000.0])
	# Object space: the map's z is the object's +Z, whatever the surface faces.
	var object := bake_with(mesh, vector_material(vector_map_of(field, Vector3(0.0, 0.0, 1.0)), m, {"vector_displacement_space": 1}), {"max_error": tolerance})
	var largest := Vector3.ZERO
	var obj_arrays := object.mesh.surface_get_arrays(0)
	var ov: PackedVector3Array = obj_arrays[Mesh.ARRAY_VERTEX]
	var ouv: PackedVector2Array = obj_arrays[Mesh.ARRAY_TEX_UV]
	var worst_object := 0.0
	for i in ov.size():
		var off: Vector3 = ov[i] - rest.call(ouv[i])
		largest = largest.max(off.abs())
		worst_object = maxf(worst_object, off.distance_to(Vector3(0.0, 0.0, m * Harness.sample_field(field, ouv[i]))))
	check(worst_object < tolerance and largest.y < 1e-6 and largest.z > 0.9 * m, "object space: (0, 0, 1) moves the plane along +Z, not along its normal (%.1f mm)" % (largest.z * 1000.0))
	# Closed meshes stay closed: welded positions move by the same vector across UV seams.
	var waves := Harness.make_wave_field(128)
	var box := BoxMesh.new()
	var boxed := bake_with(box, vector_material(vector_map_of(waves, Vector3(0.6, 0.4, 0.8)), 0.04,
		{"vector_displacement_signed": false}), {"max_error": 0.001, "max_triangles": 60000})
	var edges := {}
	if boxed.mesh != null:
		for tri: Array in triangles_of(boxed.mesh):
			var keys := [_weld(tri[0]), _weld(tri[1]), _weld(tri[2])]
			if keys[0] == keys[1] or keys[1] == keys[2] or keys[0] == keys[2]:
				continue
			for k in 3:
				var ka: Vector3i = keys[k]
				var kb: Vector3i = keys[(k + 1) % 3]
				var key := [ka, kb] if [ka.x, ka.y, ka.z] < [kb.x, kb.y, kb.z] else [kb, ka]
				edges[key] = edges.get(key, 0) + 1
	var open := 0
	for key in edges:
		if edges[key] != 2:
			open += 1
	check(boxed.mesh != null and not edges.is_empty() and open == 0, "a vector-displaced box stays closed (%d edges, %d open)" % [edges.size(), open])
	# A vector map that is off (scale 0) changes nothing: the same cache key as without it.
	var height_only := uv_material(field, 0.05)
	var with_off := uv_material(field, 0.05, {"vector_displacement_texture": vector_map_of(field, coefs), "vector_displacement_m": 0.0})
	var with_on := uv_material(field, 0.05, {"vector_displacement_texture": vector_map_of(field, coefs), "vector_displacement_m": 0.01})
	var key_of := func(mat: Material) -> String:
		var mats: Array[Material] = [mat]
		return GADSMeshBaker.cache_key(mesh, mats, Transform3D.IDENTITY, {"max_error": tolerance})
	check(key_of.call(height_only) == key_of.call(with_off) and key_of.call(with_on) != key_of.call(height_only),
		"a vector map with scale 0 bakes as before (same cache key); with a scale it is a different bake")
	# On top of a height map: both add up.
	var both := bake_with(mesh, uv_material(field, 0.03, {"vector_displacement_texture": vector_map_of(field, coefs), "vector_displacement_m": m,
		"vector_displacement_signed": true}), {"max_error": tolerance})
	var both_arrays := both.mesh.surface_get_arrays(0)
	var bv: PackedVector3Array = both_arrays[Mesh.ARRAY_VERTEX]
	var buv: PackedVector2Array = both_arrays[Mesh.ARRAY_TEX_UV]
	var worst_both := 0.0
	for i in bv.size():
		var want: Vector3 = expect.call(buv[i]) + (frame[3] as Vector3) * 0.03 * Harness.sample_field(field, buv[i])
		worst_both = maxf(worst_both, bv[i].distance_to(want))
	check(worst_both < tolerance, "with a height map as well, the two add up (%.3f mm)" % (worst_both * 1000.0))


## The geometry of every surface of [param m]: [triangles, sorted rounded positions].
static func _geometry_of(meshes: Array) -> Array:
	var tris := 0
	var keys := {}
	for m: Mesh in meshes:
		for s in m.get_surface_count():
			var arrays := m.surface_get_arrays(s)
			tris += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3 if arrays[Mesh.ARRAY_INDEX] != null else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
			for p: Vector3 in arrays[Mesh.ARRAY_VERTEX]:
				keys[Vector3i((p * 1e4).round())] = true
	var sorted := keys.keys()
	sorted.sort()
	return [tris, sorted]


## Whether the triangles of [param m] wind so that their front faces look along the vertex
## normals (Godot: clockwise seen from the front); the fraction of triangles that do.
static func _front_facing(m: Mesh) -> float:
	var good := 0
	var total := 0
	for s in m.get_surface_count():
		var arrays := m.surface_get_arrays(s)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for t in range(0, idx.size(), 3):
			var face := (v[idx[t + 1]] - v[idx[t]]).cross(v[idx[t + 2]] - v[idx[t]])
			if face.length_squared() < 1e-14:
				continue
			total += 1
			# Clockwise front faces: the right-handed cross product points away from the front.
			good += 1 if face.dot(n[idx[t]] + n[idx[t + 1]] + n[idx[t + 2]]) < 0.0 else 0
	return float(good) / maxf(total, 1)


## Export: a bake written as glTF binary and read back is the same geometry, facing the same way,
## with its material as a plain PBR material; as OBJ it has every vertex and triangle, faces wound
## counter-clockwise around their normals and a material library with the albedo; a clustered
## bake exports every cluster; nothing baked, nothing exported.
func test_export() -> void:
	var field := bump_field(128, 0.1)
	var albedo := Image.create(16, 16, false, Image.FORMAT_RGB8)
	albedo.fill(Color(0.8, 0.3, 0.2))
	var mat := uv_material(field, 0.05, {"albedo_texture": ImageTexture.create_from_image(albedo), "roughness_scale": 0.6})
	mat.resource_name = "Rock"
	var node := _make_node(mat)
	root.add_child(node)
	check(node.export_baked("user://gads_export/none.glb") == ERR_UNCONFIGURED, "nothing baked: nothing exported")
	node.bake()
	var dir := "user://gads_export"
	var glb := dir.path_join("bump.glb")
	check(node.export_baked(glb) == OK and FileAccess.file_exists(glb), "export_baked writes a .glb")
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var read_back: Node = doc.generate_scene(state) if doc.append_from_file(ProjectSettings.globalize_path(glb), state) == OK else null
	var meshes := []
	var materials := []
	if read_back != null:
		for mi: Node in read_back.find_children("*", "MeshInstance3D", true, false):
			var m: Mesh = (mi as MeshInstance3D).mesh
			meshes.append(m)
			for s in m.get_surface_count():
				materials.append(m.surface_get_material(s))
	var want := _geometry_of([node.mesh])
	var got := _geometry_of(meshes)
	print("  %d triangles, %d positions; read back %d, %d" % [want[0], (want[1] as Array).size(), got[0], (got[1] as Array).size()])
	check(meshes.size() == 1 and got[0] == want[0] and got[1] == want[1], "read back: the same triangles at the same positions (0.1 mm)")
	check(meshes.size() == 1 and _front_facing(meshes[0]) > 0.99 and _front_facing(node.mesh) > 0.99, "facing the same way")
	var std := materials[0] as BaseMaterial3D if materials.size() == 1 else null
	check(std != null and std.albedo_texture != null and is_equal_approx(snappedf(std.roughness, 0.01), 0.6),
		"with the material's albedo texture and roughness as a PBR material")
	if read_back != null:
		read_back.free()
	# OBJ.
	var obj := dir.path_join("bump.obj")
	check(node.export_baked(obj) == OK and FileAccess.file_exists(dir.path_join("bump.mtl")), "export_baked writes an .obj and its .mtl")
	var lines := FileAccess.get_file_as_string(obj).split("\n")
	var vs: Array[Vector3] = []
	var ns: Array[Vector3] = []
	var faces := []
	for line in lines:
		var parts := line.split(" ", false)
		if parts.is_empty():
			continue
		match parts[0]:
			"v":
				vs.append(Vector3(float(parts[1]), float(parts[2]), float(parts[3])))
			"vn":
				ns.append(Vector3(float(parts[1]), float(parts[2]), float(parts[3])))
			"f":
				faces.append([parts[1], parts[2], parts[3]])
	var ccw := 0
	for f: Array in faces:
		var ids := []
		for corner: String in f:
			var c := corner.split("/")
			ids.append([int(c[0]) - 1, int(c[2]) - 1])
		var face := (vs[ids[1][0]] - vs[ids[0][0]]).cross(vs[ids[2][0]] - vs[ids[0][0]])
		ccw += 1 if face.dot(ns[ids[0][1]] + ns[ids[1][1]] + ns[ids[2][1]]) > 0.0 else 0
	var vertex_count := (node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	check(vs.size() == vertex_count and ns.size() == vertex_count and faces.size() == want[0] and ccw == faces.size(),
		"the OBJ has every vertex (%d) and triangle (%d), counter-clockwise around the normals (%d)" % [vs.size(), faces.size(), ccw])
	var mtl := FileAccess.get_file_as_string(dir.path_join("bump.mtl"))
	check(mtl.contains("newmtl surface_0_Rock") and mtl.contains("map_Kd bump_0_albedo.png") and FileAccess.file_exists(dir.path_join("bump_0_albedo.png")),
		"the material library names the material and its albedo, written as PNG")
	# Clusters.
	node.quality = GADSMeshInstance3D.Quality.HIGH
	node.cluster_triangles = 300
	node.bake(true)
	var clustered := dir.path_join("clusters.glb")
	node.export_baked(clustered)
	doc = GLTFDocument.new()
	state = GLTFState.new()
	read_back = doc.generate_scene(state) if doc.append_from_file(ProjectSettings.globalize_path(clustered), state) == OK else null
	var parts_back := read_back.find_children("*", "MeshInstance3D", true, false) if read_back != null else []
	var cluster_meshes: Array = parts_back.map(func(mi: Node) -> Mesh: return (mi as MeshInstance3D).mesh)
	check(parts_back.size() == node.get_cluster_count() and parts_back.size() > 1 and _geometry_of(cluster_meshes)[0] == int(node.bake_stats.get("triangles", -1)),
		"a clustered bake exports every cluster (%d objects)" % parts_back.size())
	if read_back != null:
		read_back.free()
	node.queue_free()
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir.path_join(f)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))
	await process_frame


## A GADSManager's shared runtime budget limits a view-dependent mesh's tessellation, and its
## adaptive quality coarsens it.
func test_runtime_budget() -> void:
	var s := h.new_debug_scene()
	var gads := GADSManager.new()
	s.add_child(gads)
	var field := Harness.make_stone_field(256, 60, 11)
	var node := _make_node(uv_material(field, 0.05))
	node.source_mesh = plane(8.0)
	node.view_dependent = true
	node.view_max_triangles = 400000
	s.add_child(node)
	h.add_camera(Vector3(-3.5, 0.6, -3.5), Vector3(0, 0, 0))
	var done := []
	node.view_tessellated.connect(func(stats: Dictionary) -> void: done.append(stats))
	var wait_for := func(count: int) -> void:
		for i in 900:
			if done.size() >= count and not node.is_view_tessellating():
				return
			await process_frame
	await wait_for.call(1)
	var free_triangles: int = done.back()["triangles"] if not done.is_empty() else 0
	check(node.is_in_group(&"gads_view_dependent") and node.get_runtime_max_triangles() == 400000, "without a shared budget it has its own")
	gads.runtime_triangle_budget = 1500
	gads.distribute_runtime_budget()
	check(node.get_runtime_max_triangles() == 1500, "a shared budget limits it (the only one: all of it)")
	await wait_for.call(2)
	var limited: int = done.back()["triangles"] if done.size() >= 2 else 0
	print("  own budget %d triangles, shared budget 1500: %d" % [free_triangles, limited])
	check(done.size() >= 2 and limited <= 1510 and limited < free_triangles, "and it tessellates again within it (the last split may add a triangle)")
	gads.runtime_triangle_budget = 0
	gads.adaptive_quality = true
	gads.set_process(false)
	for i in 300:
		gads.adapt_to(40.0, 1.0 / 60.0)
	gads.distribute_runtime_budget()
	check(gads.get_adapt_level() >= 2 and is_equal_approx(node.get_runtime_pixel_error(), node.pixel_error * gads.get_runtime_detail_scale()),
		"the adaptive quality makes it coarser (pixel error x %.2f)" % gads.get_runtime_detail_scale())
	var before := done.size()
	await wait_for.call(before + 1)
	var coarse: int = done.back()["triangles"] if done.size() > before else free_triangles
	print("  adaptive level %d: %d triangles" % [gads.get_adapt_level(), coarse])
	check(done.size() > before and coarse < free_triangles, "and it tessellates again, coarser")
	gads.adaptive_quality = false
	h.clear_scene()
	await process_frame


## Sculpting: picking finds the uv under a ray; a sculpt map raises the baked surface by its
## offsets at the source uvs, on a mesh without any relief and on top of a relief; the bake key
## follows it; removing it bakes flat again.
## Blend shapes: the bake keeps them (names, mode), each vertex moved by the shape's offset
## interpolated from the source vertices (linear across the plane here), normals following.
func test_blend_shapes() -> void:
	var source := plane()
	var arrays := source.get_mesh_arrays()
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var lifted := v.duplicate()
	for i in lifted.size():
		lifted[i].y += 0.25 * (v[i].x + 1.0)
	var shape := []
	shape.resize(Mesh.ARRAY_MAX)
	shape[Mesh.ARRAY_VERTEX] = lifted
	shape[Mesh.ARRAY_NORMAL] = arrays[Mesh.ARRAY_NORMAL]
	shape[Mesh.ARRAY_TANGENT] = arrays[Mesh.ARRAY_TANGENT]
	var morph := ArrayMesh.new()
	morph.add_blend_shape("lift")
	morph.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [shape])
	var baker := bake_with(morph, uv_material(bump_field(128, 0.1), 0.03), {"lods": true})
	check(baker.mesh != null and baker.mesh.get_blend_shape_count() == 1 and baker.mesh.get_blend_shape_name(0) == &"lift", "a mesh with blend shapes bakes and keeps them")
	if baker.mesh == null:
		return
	var base := baker.mesh.surface_get_arrays(0)
	var shapes := baker.mesh.surface_get_blend_shape_arrays(0)
	var bv: PackedVector3Array = base[Mesh.ARRAY_VERTEX]
	var sv: PackedVector3Array = shapes[0][Mesh.ARRAY_VERTEX]
	var rest: PackedFloat32Array = base[Mesh.ARRAY_CUSTOM0]
	var worst := 0.0
	for i in bv.size():
		var expected := Vector3(0, 0.25 * (rest[i * 4] + 1.0), 0)
		worst = maxf(worst, (sv[i] - bv[i]).distance_to(expected))
	print("  %d vertices: the shape's offset within %.4f mm of the interpolated one" % [bv.size(), worst * 1000.0])
	check(bv.size() > 100 and sv.size() == bv.size() and worst < 1e-4, "each baked vertex moves by the shape's offset interpolated from the source vertices")
	var mesh_node := MeshInstance3D.new()
	mesh_node.mesh = baker.mesh
	root.add_child(mesh_node)
	mesh_node.set_blend_shape_value(0, 1.0)
	await process_frame
	check(mesh_node.get_blend_shape_value(0) == 1.0, "the baked mesh's shape can be driven")
	mesh_node.queue_free()
	await process_frame


## Skinned meshes: the bake keeps the bone weights, interpolated between the source vertices
## (linear across the strip here), summing to 1; clusters deform with the node's skeleton.
func test_skinned() -> void:
	var source := plane()
	var arrays := source.get_mesh_arrays()
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones := PackedInt32Array()
	var weights := PackedFloat32Array()
	for p in v:
		var right := (p.x + 1.0) * 0.5
		bones.append_array([0, 1, 0, 0])
		weights.append_array([1.0 - right, right, 0.0, 0.0])
	arrays[Mesh.ARRAY_BONES] = bones
	arrays[Mesh.ARRAY_WEIGHTS] = weights
	var skinned := ArrayMesh.new()
	skinned.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var holder := Node3D.new()
	root.add_child(holder)
	var skeleton := Skeleton3D.new()
	skeleton.name = "Skeleton"
	skeleton.add_bone("left")
	skeleton.add_bone("right")
	holder.add_child(skeleton)
	var node := GADSMeshInstance3D.new()
	node.name = "Skinned"
	node.source_mesh = skinned
	node.material_override = uv_material(bump_field(128, 0.1), 0.03)
	node.cache_directory = CACHE_DIR
	node.cluster_triangles = 300
	node.skin = skeleton.create_skin_from_rest_transforms()
	skeleton.add_child(node)
	node.skeleton = node.get_path_to(skeleton)
	check(GADSMeshBaker.check_mesh(skinned) == "" and node.bake() == OK, "a skinned mesh bakes")
	var count := 0
	var worst := 0.0
	var sums := 0.0
	var clusters := GADSMeshInstance3D.cluster_meshes_of(node.mesh)
	clusters.push_front(node.mesh)
	for m: Mesh in clusters:
		for s in m.get_surface_count():
			var out := m.surface_get_arrays(s)
			if out[Mesh.ARRAY_BONES] == null:
				continue
			var ov: PackedVector3Array = out[Mesh.ARRAY_VERTEX]
			var ob: PackedInt32Array = out[Mesh.ARRAY_BONES]
			var ow: PackedFloat32Array = out[Mesh.ARRAY_WEIGHTS]
			for i in ov.size():
				var right := 0.0
				var total := 0.0
				for k in 4:
					total += ow[i * 4 + k]
					if ob[i * 4 + k] == 1:
						right += ow[i * 4 + k]
				worst = maxf(worst, absf(right - (ov[i].x + 1.0) * 0.5))
				sums = maxf(sums, absf(total - 1.0))
				count += 1
	print("  %d vertices in %d meshes: weights within %.6f of the linear blend, sums within %.6f of 1" % [count, clusters.size(), worst, sums])
	check(count > 100 and worst < 1e-4 and sums < 1e-4, "the bone weights are interpolated between the source vertices and sum to 1 (as 16-bit weights)")
	var shared := not node.get_children(true).filter(func(c: Node) -> bool: return c is MeshInstance3D and c.name.begins_with("GADSCluster")).is_empty()
	for c in node.get_children(true):
		if c is MeshInstance3D and c.name.begins_with("GADSCluster"):
			shared = shared and (c as MeshInstance3D).skin == node.skin and c.get_node_or_null((c as MeshInstance3D).skeleton) == skeleton
	check(shared, "its clusters deform with the node's skin and skeleton")
	holder.queue_free()
	await process_frame


func test_bake_cache() -> void:
	var dir := CACHE_DIR.path_join("clean")
	var node := GADSMeshInstance3D.new()
	node.name = "CacheClean"
	node.source_mesh = plane()
	node.cache_directory = dir
	node.material_override = uv_material(bump_field(64, 0.1), 0.02)
	root.add_child(node)
	node.bake()
	var first := node.mesh.resource_path
	node.material_override = uv_material(bump_field(64, 0.1), 0.03)
	node.bake()
	var second := node.mesh.resource_path
	await process_frame
	var unused := GADSBakeCache.find_unused(PackedStringArray([dir]))
	check(GADSBakeCache.is_cache_file(first) and first != second and first in unused and not second in unused,
		"the earlier bake is unused, the node's own is not (%s)" % [unused])
	node.queue_free()
	await process_frame
	await process_frame
	unused = GADSBakeCache.find_unused(PackedStringArray([dir]))
	check(second in unused, "nothing holds the node's bake once it is gone")
	check(GADSBakeCache.remove(unused) == unused.size() and not FileAccess.file_exists(first) and not FileAccess.file_exists(second),
		"remove() takes them away")
	check(not GADSBakeCache.is_cache_file("res://gads_baked/notes.txt") and GADSBakeCache.is_cache_file("res://x/rock_sculpt.res")
		and GADSBakeCache.is_cache_file("res://x/rock_0123456789abcdef_collision.res") and not GADSBakeCache.is_cache_file("res://x/rock_ground.res")
		and GADSBakeCache.is_cache_file("res://x/rock_painted.mesh") and GADSBakeCache.is_cache_file("res://x/rock_painted_2.mesh")
		and not GADSBakeCache.is_cache_file("res://x/rock_painted.tres"),
		"only files named like bakes, collision shapes, sculpt maps and painted meshes count")
	check(GADSBakeCache.dependency_path("uid://abc::ArrayMesh::res://a/b.mesh") == "res://a/b.mesh"
		and GADSBakeCache.dependency_path("res://a/b.mesh::ArrayMesh") == "res://a/b.mesh", "dependency entries give their path")


## stream_bake: the scene keeps the bake's path, the bake loads near the camera and goes far away.
func test_stream() -> void:
	var s := h.new_debug_scene()
	var node := _make_node(uv_material(bump_field(64, 0.08), 0.05))
	node.name = "Streamed"
	node.geometry_range = 5.0
	node.geometry_range_margin = 1.0
	node.stream_margin = 4.0
	s.add_child(node)
	check(node.bake(true) == OK, "a saved bake")
	var path: String = node.bake_stats.get("path", "")
	var triangles := GADSProfiler.mesh_triangles(node.mesh)
	var cam := h.add_camera(Vector3(0, 2, 40), Vector3.ZERO)
	var events := []
	node.bake_streamed.connect(func(loaded: bool) -> void: events.append(loaded))
	node.stream_bake = true
	check(node.is_streaming() and is_equal_approx(node.get_stream_distance(), 10.0), "it streams, loading within 10 m")
	check(events == [false] and node.mesh == null and not node.is_bake_loaded() and node.baked,
		"40 m away the bake is let go (still baked)")
	check(node.get_fallback() != null and node.get_fallback().visibility_range_begin == 0.0,
		"meanwhile the source mesh draws with parallax at every distance")
	check(not ResourceLoader.has_cached(path), "its memory is freed")
	var report := GADSProfiler.collect(s)
	var o: Dictionary = report["objects"][0]
	check(o["streamed"] and o["streamed_out"] and o["memory_bytes"] == 0 and report["totals"]["streamed_out"] == 1,
		"the profiler counts it as streamed out, using no memory")
	cam.global_position = Vector3(0, 2, 8)
	node.update_stream(true)
	check(events == [false, true] and node.is_bake_loaded() and GADSProfiler.mesh_triangles(node.mesh) == triangles,
		"8 m away it loads again (the same %d triangles)" % triangles)
	check(node.get_fallback().visibility_range_begin == 5.0, "and shows within the geometry range")
	cam.global_position = Vector3(0, 2, 12)
	node.update_stream()
	check(node.is_bake_loaded(), "12 m away it stays (within the stream margin beyond 10 m)")
	cam.global_position = Vector3(0, 2, 40)
	node.update_stream()
	check(not node.is_bake_loaded() and events.size() == 3, "40 m away it goes again")
	cam.global_position = Vector3(0, 2, 6)
	var waited := 0
	while not node.is_bake_loaded() and waited < 300:
		await process_frame
		waited += 1
	check(node.is_bake_loaded(), "the node loads it in the background by itself (%d frames)" % waited)
	var packed := PackedScene.new()
	packed.pack(node)
	var scene_path := CACHE_DIR.path_join("streamed.tscn")
	var binary_path := CACHE_DIR.path_join("streamed.scn")
	ResourceSaver.save(packed, scene_path)
	ResourceSaver.save(packed, binary_path)
	var text := FileAccess.get_file_as_string(scene_path)
	check(not text.contains('path="%s"' % path) and text.contains('"%s"' % path), "the scene stores the bake's path, not the mesh")
	check(path in GADSBakeCache.paths_in_file(scene_path) and path in GADSBakeCache.paths_in_file(binary_path),
		"the cache tools find the path in text and binary scenes")
	check(node.get_bake_summary().contains("Streamed: loads within 10.0 m"), "the summary says it streams")
	node.queue_free()
	await process_frame
	cam.global_position = Vector3(0, 2, 40)
	var copy := (ResourceLoader.load(scene_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate() as GADSMeshInstance3D
	s.add_child(copy)
	check(copy.baked and copy.mesh == null and copy.is_streaming() and copy.get_fallback() != null,
		"loaded 40 m away, the scene's node holds no baked mesh")
	check(copy.get_baked_mesh() != null and copy.mesh == null, "get_baked_mesh() loads it without showing it")
	cam.global_position = Vector3(0, 2, 6)
	copy.update_stream(true)
	check(copy.is_bake_loaded() and not copy.is_bake_stale(), "near, it loads its bake (still current)")
	cam.global_position = Vector3(0, 2, 40)
	copy.update_stream()
	copy.stream_bake = false
	check(copy.is_bake_loaded() and not copy.is_streaming(), "turning streaming off loads the bake for good")
	check(copy.get_fallback().visibility_range_begin == 5.0, "and the geometry range works as without streaming")
	copy.queue_free()
	h.clear_scene()
	await process_frame


## GADSVertexPaint: a painted copy, brush dabs on a colour channel (falloff, erase, smooth, fill),
## colours through undo, the bake key following the paint, and the bake following the painted
## layer mask.
func test_vertex_paint() -> void:
	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(2, 2)
	plane_mesh.subdivide_width = 15
	plane_mesh.subdivide_depth = 15
	var source := ArrayMesh.new()
	source.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, plane_mesh.get_mesh_arrays())
	var painted := GADSVertexPaint.make_paintable(source)
	var colors: PackedColorArray = painted.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var positions: PackedVector3Array = painted.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	check(painted != source and GADSVertexPaint.is_paintable(painted) and not GADSVertexPaint.is_paintable(source)
		and colors.size() == positions.size() and Array(colors).all(func(c: Color) -> bool: return c == Color.WHITE),
		"make_paintable() copies the mesh with white vertex colours (the layers look the same)")
	check(GADSProfiler.mesh_triangles(painted) == GADSProfiler.mesh_triangles(source), "with the same triangles")
	var painter := GADSVertexPaint.new(painted)
	painter.fill(0, 0.0)
	var centre := Vector3(0.5, 0, 0)
	var changed := painter.dab(centre, 0.4, GADSVertexPaint.Mode.PAINT, 0, 1.0)
	colors = painted.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var worst := 0.0
	var outside := 0.0
	for i in positions.size():
		var d := positions[i].distance_to(centre) / 0.4
		var expected := 0.0 if d >= 1.0 else pow(1.0 - d * d, 2.0)
		if d >= 1.0:
			outside = maxf(outside, colors[i].r)
		worst = maxf(worst, absf(colors[i].r - expected))
	print("  %d vertices painted; red off the falloff by at most %.4f" % [changed, worst])
	check(changed > 20 and worst < 1.5 / 255.0 and outside == 0.0, "a dab paints red with the brush's falloff, nothing beyond its radius (read back from the mesh)")
	check(Array(colors).all(func(c: Color) -> bool: return c.g == 1.0 and c.b == 1.0), "and leaves the other channels alone")
	var at_centre := -1
	for i in positions.size():
		if positions[i].distance_to(centre) < 1e-4:
			at_centre = i
	var before := painter.get_colors()
	painter.dab(centre, 0.4, GADSVertexPaint.Mode.ERASE, 0, 0.5)
	var erased: float = painted.surface_get_arrays(0)[Mesh.ARRAY_COLOR][at_centre].r
	check(absf(erased - 0.5) < 1.5 / 255.0, "Erase at half strength halves the centre (%.3f)" % erased)
	var spread := func(cs: PackedColorArray) -> float:
		var lo := 1.0
		var hi := 0.0
		for i in positions.size():
			if positions[i].distance_to(centre) < 0.3:
				lo = minf(lo, cs[i].r)
				hi = maxf(hi, cs[i].r)
		return hi - lo
	var spread_before: float = spread.call(painter.get_colors()[0])
	for k in 4:
		painter.dab(centre, 0.4, GADSVertexPaint.Mode.SMOOTH, 0, 1.0)
	var spread_after: float = spread.call(painter.get_colors()[0])
	check(spread_after < 0.5 * spread_before, "Smooth evens the channel out (spread %.3f -> %.3f)" % [spread_before, spread_after])
	painter.set_colors(before)
	var restored: PackedColorArray = painted.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var same := true
	for i in restored.size():
		same = same and absf(restored[i].r - before[0][i].r) < 1.5 / 255.0
	check(same, "set_colors() puts earlier colours back (undo)")
	# The bake key follows the paint at once (the file's time changes only once a second).
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	var path := CACHE_DIR.path_join("plane_painted.mesh")
	GADSVertexPaint.update_hash(painted)
	ResourceSaver.save(painted, path)
	painted.take_over_path(path)
	var flat := Image.create(16, 16, false, Image.FORMAT_RF)
	var ones := Image.create(16, 16, false, Image.FORMAT_RF)
	ones.fill(Color(1, 0, 0))
	var mat := GADSMaterials.create_layered(GADSMaterials.Mapping.UV, {"height": ImageTexture.create_from_image(flat)},
		{"height_m": 0.04, "height_center": 0.0},
		[{"height": ImageTexture.create_from_image(ones), "height_m": 0.04, "mask": GADSMaterials.LayerMask.VERTEX_R, "amount": 1.0, "blend_width": 0.1}],
		GADSMaterials.Quality.POM)
	var node := _make_node(mat)
	node.source_mesh = painted
	node.quality = GADSMeshInstance3D.Quality.MEDIUM
	root.add_child(node)
	var key := node.compute_bake_key()
	painter.dab(Vector3(-0.5, 0, 0), 0.3, GADSVertexPaint.Mode.PAINT, 0, 1.0)
	GADSVertexPaint.update_hash(painted)
	check(node.compute_bake_key() != key, "painting changes the bake key at once (the colours' hash)")
	check(node.bake() == OK, "the painted mesh bakes")
	var out := node.mesh.surface_get_arrays(0)
	var v: PackedVector3Array = out[Mesh.ARRAY_VERTEX]
	var top := {}
	for p: Vector3 in v:
		for spot: Vector3 in [Vector3(0.5, 0, 0), Vector3(-0.5, 0, 0), Vector3(0, 0, 0.75)]:
			if Vector2(p.x - spot.x, p.z - spot.z).length() < 0.05:
				top[spot] = maxf(top.get(spot, -1.0), p.y)
	print("  baked heights: painted centres %.1f / %.1f mm, unpainted %.1f mm" % [top.get(Vector3(0.5, 0, 0), -1.0) * 1000.0,
		top.get(Vector3(-0.5, 0, 0), -1.0) * 1000.0, top.get(Vector3(0, 0, 0.75), -1.0) * 1000.0])
	check(top.get(Vector3(0.5, 0, 0), 0.0) > 0.03 and top.get(Vector3(-0.5, 0, 0), 0.0) > 0.03,
		"the bake raises the layer where it is painted")
	check(absf(top.get(Vector3(0, 0, 0.75), 1.0)) < 0.002, "and not where it is not")
	node.queue_free()
	await process_frame


## GADSManager.prop_geometry: the nearest plain MeshInstance3D props with UV or triplanar relief
## get a runtime tessellation drawing in their place while the camera is near, and draw their
## parallax again when it leaves; world-planar ground, opted-out and far props do not.
func test_prop_geometry() -> void:
	var s := h.new_debug_scene()
	var field := bump_field(128, 0.1)
	var make := func(node_name: String, pos: Vector3, mat: Material) -> MeshInstance3D:
		var mi := MeshInstance3D.new()
		mi.name = node_name
		mi.mesh = plane()
		mi.material_override = mat
		mi.position = pos
		s.add_child(mi)
		return mi
	var near := make.call("Near", Vector3(0, 0, 0), uv_material(field, 0.08)) as MeshInstance3D
	var second := make.call("Second", Vector3(3, 0, 0), uv_material(field, 0.08)) as MeshInstance3D
	var third := make.call("Third", Vector3(-3, 0, 0), uv_material(field, 0.08)) as MeshInstance3D
	var far := make.call("Far", Vector3(0, 0, -40), uv_material(field, 0.08)) as MeshInstance3D
	var ground := make.call("Ground", Vector3(0, 0, 3), GADSMaterials.create(GADSMaterials.Mapping.WORLD,
		{"height": ImageTexture.create_from_image(field["image"])}, {"height_m": 0.05, "height_center": 0.0}, GADSMaterials.Quality.POM)) as MeshInstance3D
	var opted := make.call("OptedOut", Vector3(0, 0, -3), uv_material(field, 0.08)) as MeshInstance3D
	opted.add_to_group(GADSPropGeometry.OPT_OUT_GROUP)
	check(not GADSPropGeometry.is_candidate(ground) and not GADSPropGeometry.is_candidate(opted) and GADSPropGeometry.is_candidate(near),
		"world-planar ground and opted-out props are not candidates")
	var manager := GADSManager.new()
	manager.preset = GADSSettings.Preset.HIGH
	manager.prop_geometry_range = 5.0
	manager.prop_geometry_max = 2
	manager.prop_geometry = true
	s.add_child(manager)
	var cam := h.add_camera(Vector3(0.5, 2.0, 2.5), Vector3(0, 0, 0), 60.0)
	var waited := 0
	while manager.get_prop_geometry_nodes().size() < 2 and waited < 900:
		await process_frame
		waited += 1
	var nodes := manager.get_prop_geometry_nodes()
	print("  props with geometry after %d frames: %s" % [waited, nodes.map(func(n: Node) -> String: return String(n.name))])
	check(nodes.size() == 2 and near in nodes and not far in nodes and not ground in nodes and not opted in nodes,
		"the two nearest props get geometry (max 2), not the far one, the ground or the opted-out one")
	var proxy := manager._props.get_proxy(near)
	var tris := GADSProfiler.mesh_triangles(proxy.mesh) if proxy != null else 0
	check(proxy != null and proxy.visible and proxy.mesh is ArrayMesh and tris > 10 * GADSProfiler.mesh_triangles(near.mesh) and near.get_child_count() == 0,
		"an internal, view-dependent tessellation (%d triangles) draws in its place" % tris)
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(GADSManager.DebugView.TESSELLATION, 0.1, 0, 0))
	await h.frames(3)
	var px := cam.unproject_position(Vector3(0, 0.05, 0))
	var c_near := (await h.capture()).get_pixelv(Vector2i(px))
	cam.global_position = Vector3(0.5, 30.0, 30.0)
	manager.update_prop_geometry()
	await h.frames(3)
	var px_far := cam.unproject_position(Vector3(0, 0.05, 0))
	var c_far := (await h.capture()).get_pixelv(Vector2i(px_far))
	GADSGlobals.set_value(GADSGlobals.DEBUG, Vector4(0, 0.1, 0, 0))
	print("  the near prop in the Tessellation view: %s near, %s far" % [c_near, c_far])
	check(maxf(c_near.r, c_near.g) > c_near.b, "near, the prop draws refined geometry (green and warmer)")
	check(manager.get_prop_geometry_nodes().is_empty() and c_far.b > c_far.r, "far away it draws its parallax again")
	cam.global_position = Vector3(0.5, 2.0, 2.5)
	manager.update_prop_geometry()
	manager.prop_geometry = false
	check(manager.get_prop_geometry_nodes().is_empty(), "turning it off lets them go")
	h.clear_scene()
	await process_frame


func test_sculpt() -> void:
	var node := GADSMeshInstance3D.new()
	node.name = "Sculpted"
	node.source_mesh = plane()
	node.material_override = StandardMaterial3D.new()
	node.cache_directory = CACHE_DIR
	node.quality = GADSMeshInstance3D.Quality.HIGH
	node.sculpt_resolution = 128
	root.add_child(node)
	var hit := GADSSculpt.pick(node.source_mesh, Vector3(0.3, 1.0, -0.4), Vector3.DOWN)
	var want_uv := Vector2((0.3 + 1.0) / 2.0, (-0.4 + 1.0) / 2.0)
	check(not hit.is_empty() and (hit["uv"] as Vector2).distance_to(want_uv) < 1e-4 and absf(float(hit["uv_per_m"]) - 0.5) < 1e-4,
		"pick() finds the uv under a ray (%s) and the uv units per metre" % [hit.get("uv")])
	var flat_key := node.compute_bake_key()
	check(node.get_relief_depth() == 0.0, "no relief and no sculpt: nothing to bake")
	var img := node.get_sculpt_image()
	GADSSculpt.dab(img, Vector2(0.5, 0.5), 0.25, GADSSculpt.Mode.RAISE, 0.05)
	var done := []
	node.bake_finished.connect(func(ok: bool) -> void: done.append(ok))
	node.sculpt_changed()
	for i in 600:
		if not done.is_empty():
			break
		await process_frame
	check(done == [true] and node.baked and node.sculpt_map != null, "sculpt_changed() bakes the sculpted surface")
	if node.baked:
		var arrays := node.mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var worst := 0.0
		var top := 0.0
		for i in v.size():
			worst = maxf(worst, absf(v[i].y - GADSDisplacementField3D.sample_repeat(img, uv[i])))
			top = maxf(top, v[i].y)
		print("  %d triangles, top %.1f mm (5 cm raised), vertices within %.3f mm of the map" % [triangle_count(node.mesh), top * 1000.0, worst * 1000.0])
		check(worst < 0.001 and top > 0.045 and triangle_count(node.mesh) > 50, "vertices rise by the sculpt map at their uvs, refined where it changes")
	check(node.compute_bake_key() != flat_key and absf(node.get_relief_depth() - 0.05) < 0.002, "the bake key and the relief depth follow the sculpt")
	# Another stroke that leaves the depth as it is still changes the key (a stale bake must not load).
	var sculpted_key := node.compute_bake_key()
	var other := img.duplicate() as Image
	GADSSculpt.dab(other, Vector2(0.15, 0.15), 0.05, GADSSculpt.Mode.RAISE, 0.01)
	node.set_sculpt_image(other)
	var other_key := node.compute_bake_key()
	node.set_sculpt_image(img)
	check(other_key != sculpted_key and node.compute_bake_key() == sculpted_key, "a stroke elsewhere changes the bake key, the same map gives the same key")
	for i in 600:
		if not node.is_baking():
			break
		await process_frame
	# On top of a material's relief.
	var field := bump_field(128, 0.1)
	node.material_override = uv_material(field, 0.03)
	done.clear()
	node.bake_async(false)
	for i in 600:
		if not done.is_empty():
			break
		await process_frame
	if node.baked:
		var arrays := node.mesh.surface_get_arrays(0)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var worst := 0.0
		for i in v.size():
			worst = maxf(worst, absf(v[i].y - GADSDisplacementField3D.sample_repeat(img, uv[i]) - 0.03 * Harness.sample_field(field, uv[i])))
		check(worst < 0.001, "on top of a material's relief they add up (%.3f mm)" % (worst * 1000.0))
	done.clear()
	node.material_override = StandardMaterial3D.new()
	node.set_sculpt_image(null)
	check(node.sculpt_map == null and node.compute_bake_key() == flat_key, "removing the sculpt map restores the original bake key")
	node.queue_free()
	await process_frame
