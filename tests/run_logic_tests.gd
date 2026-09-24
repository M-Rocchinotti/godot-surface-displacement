extends SceneTree
## Headless logic tests (no rendering needed):
##     python tools/godot.py --headless --script tests/run_logic_tests.gd
## Exit code 0 = all passed.

const Builder := preload("res://demo/scenes/demo_builder.gd")

var _passed := 0
var _failed := 0


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	test_variants()
	test_presets()
	test_manager()
	test_field_geometry()
	test_field_mesh_seams()
	test_ground_bake_sampling()
	test_demo_textures()
	await test_node_lifetime()
	print("\nlogic tests: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("  ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL %s" % what)


# --- Shader variants -------------------------------------------------------------------------

func test_variants() -> void:
	print("\n== shader variants")
	var count := 0
	var ok := true
	for m in SDMaterials.MAPPING_NAMES.size():
		for q in SDMaterials.QUALITY_NAMES.size():
			for depth in [false, true]:
				var path := SDMaterials.variant_path(m, q, depth)
				var shader := load(path) as Shader
				if shader == null:
					ok = false
					print("  missing variant %s" % path)
					continue
				count += 1
				var info := SDMaterials.parse(shader)
				var want_depth: bool = depth and q != SDMaterials.Quality.FLAT
				ok = ok and info.get("mapping") == m and info.get("quality") == q and info.get("depth_write") == want_depth
				# Each variant defines exactly what its name says (the generator is the source).
				var code := shader.code
				ok = ok and code.contains("#define SD_POM") == (q != SDMaterials.Quality.FLAT)
				ok = ok and code.contains("#define SD_SELF_SHADOW") == (q == SDMaterials.Quality.POM_SELF_SHADOW)
				ok = ok and code.contains("#define SD_DEPTH_WRITE") == want_depth
	check(ok, "every mapping x quality x depth variant exists, parses back and defines what its name says (%d loaded)" % count)
	check(SDMaterials.parse(null).is_empty() and not SDMaterials.is_sd_material(StandardMaterial3D.new()), "other shaders and materials are not taken for SD variants")
	var mat := SDMaterials.create(SDMaterials.Mapping.UV, {}, {"height_m": 0.02}, SDMaterials.Quality.POM, true)
	SDMaterials.set_quality(mat, SDMaterials.Quality.FLAT)
	var flat_info := SDMaterials.parse(mat.shader)
	SDMaterials.set_quality(mat, SDMaterials.Quality.POM_SELF_SHADOW)
	var back := SDMaterials.parse(mat.shader)
	check(flat_info["quality"] == SDMaterials.Quality.FLAT and back["depth_write"] == true and back["quality"] == SDMaterials.Quality.POM_SELF_SHADOW,
			"the opt-in depth write survives a switch to flat and back")
	check(is_equal_approx(float(mat.get_shader_parameter("height_m")), 0.02), "switching variants keeps the material's parameters")
	SDMaterials.set_depth_write(mat, false)
	SDMaterials.set_quality(mat, SDMaterials.Quality.FLAT)
	SDMaterials.set_quality(mat, SDMaterials.Quality.POM)
	check(not SDMaterials.parse(mat.shader)["depth_write"], "opting out of the depth write sticks")


# --- Presets -----------------------------------------------------------------------------------

func test_presets() -> void:
	print("\n== presets")
	var off := SDSettings.create_preset(SDSettings.Preset.OFF)
	var low := SDSettings.create_preset(SDSettings.Preset.LOW)
	var med := SDSettings.create_preset(SDSettings.Preset.MEDIUM)
	var high := SDSettings.create_preset(SDSettings.Preset.HIGH)
	var epic := SDSettings.create_preset(SDSettings.Preset.EPIC)
	check(off.get_quality() == SDMaterials.Quality.FLAT and low.get_quality() == SDMaterials.Quality.POM
			and med.get_quality() == SDMaterials.Quality.POM_SELF_SHADOW, "Off = flat, Low = POM, Medium and up = POM with self-shadowing")
	check(not low.near_field_enabled and not med.near_field_enabled and high.near_field_enabled and epic.near_field_enabled,
			"near-camera geometry only at High and Epic")
	check(epic.scatter_enabled and not high.scatter_enabled, "pebble scatter only at Epic")
	check(low.pom_max_steps <= med.pom_max_steps and med.pom_max_steps <= epic.pom_max_steps and low.pom_fade_end <= med.pom_fade_end
			and med.pom_fade_end <= epic.pom_fade_end and low.pom_refine_steps < med.pom_refine_steps,
			"steps, fade distance and refinement grow with the preset")
	check(epic.near_field_resolution > high.near_field_resolution and epic.near_field_spacing < high.near_field_spacing,
			"Epic's field is denser than High's")
	var budgets := [0.5, 1.2, 2.0, 3.0]
	var ok := true
	for p in 4:
		ok = ok and is_equal_approx(SDSettings.get_budget_ms(p + 1), budgets[p])
	check(ok, "budgets 0.5 / 1.2 / 2.0 / 3.0 ms for Low / Medium / High / Epic")


# --- SurfaceDisplacement node ----------------------------------------------------------------

func test_manager() -> void:
	print("\n== SurfaceDisplacement node")
	var scene := Node3D.new()
	var sd := SurfaceDisplacement.new()
	sd.preset = SDSettings.Preset.HIGH
	scene.add_child(sd)
	var mat := SDMaterials.create(SDMaterials.Mapping.WORLD, {}, {}, SDMaterials.Quality.POM)
	var mi := MeshInstance3D.new()
	mi.mesh = PlaneMesh.new()
	mi.material_override = mat
	scene.add_child(mi)
	root.add_child(scene)
	sd.apply()
	check(SDMaterials.parse(mat.shader)["quality"] == SDMaterials.Quality.POM_SELF_SHADOW, "materials in the scene switch to the preset's variant")
	check(SurfaceDisplacement.find_in(self) == sd, "find_in() finds the node")
	sd.set_feature(SurfaceDisplacement.Feature.SELF_SHADOW, false)
	sd.apply()
	check(SDMaterials.parse(mat.shader)["quality"] == SDMaterials.Quality.POM, "switching self-shadowing off selects the POM variant")
	sd.set_feature(SurfaceDisplacement.Feature.POM, false)
	sd.apply()
	check(SDMaterials.parse(mat.shader)["quality"] == SDMaterials.Quality.FLAT and not sd.is_feature_active(SurfaceDisplacement.Feature.SELF_SHADOW),
			"switching POM off selects the flat variant and implies no self-shadowing")
	sd.pom = true
	sd.self_shadow = true
	sd.preset = SDSettings.Preset.LOW
	sd.near_field = true
	sd.apply()
	check(not sd.is_feature_active(SurfaceDisplacement.Feature.NEAR_FIELD), "a feature switch cannot add what the preset leaves out")
	sd.preset = SDSettings.Preset.EPIC
	sd.near_field = false
	sd.apply()
	check(not sd.is_feature_active(SurfaceDisplacement.Feature.SCATTER), "pebble scatter needs the near-camera geometry")
	var late := SDMaterials.create(SDMaterials.Mapping.UV, {}, {}, SDMaterials.Quality.FLAT)
	var mi2 := MeshInstance3D.new()
	mi2.mesh = PlaneMesh.new()
	mi2.material_override = late
	scene.add_child(mi2)
	check(SDMaterials.parse(late.shader)["quality"] == SDMaterials.Quality.POM_SELF_SHADOW, "materials added later are switched as they enter the tree")
	sd.enabled = false
	sd.apply()
	check(SDMaterials.parse(mat.shader)["quality"] == SDMaterials.Quality.FLAT and is_zero_approx(sd.get_budget_ms()), "enabled = false draws everything flat")
	scene.queue_free()


# --- DisplacementField3D geometry ------------------------------------------------------------

func test_field_geometry() -> void:
	print("\n== field geometry")
	for preset in [SDSettings.Preset.HIGH, SDSettings.Preset.EPIC]:
		var s := SDSettings.create_preset(preset)
		var field := DisplacementField3D.new()
		field.levels = s.near_field_levels
		field.resolution = s.near_field_resolution
		field.base_spacing = s.near_field_spacing
		var delta := field.get_snap() * 0.5
		var ok := true
		for k in field.levels - 1:
			var r := field.get_morph_range(k)
			var spacing := field.base_spacing * pow(2.0, k)
			var outer := field.resolution / 2.0 * spacing
			var inner := outer * 0.5 if k > 0 else 0.0
			# Morph complete before the closest point of the ring's outer edge, not started at the
			# farthest point of its inner edge, for any camera offset within the snap cell.
			ok = ok and r.y <= outer - delta + 1e-6 and r.x < r.y
			if k > 0:
				ok = ok and r.x >= sqrt(2.0) * (inner + delta) - 1e-6
		var fade := field.get_fade_range()
		ok = ok and fade.y <= field.get_reach() - delta and fade.x < fade.y
		check(ok, "%s: morph bands fit inside their rings and the relief fades out inside the grid (reach %.1f m, snap %.2f m)" % [SDSettings.preset_name(preset), field.get_reach(), field.get_snap()])
		var o := field.snapped_origin(Vector3(1.234, 5.0, -7.777))
		check(is_zero_approx(fposmod(o.x, field.get_snap())) or is_equal_approx(fposmod(o.x, field.get_snap()), field.get_snap()),
				"%s: the origin snaps to the coarsest lattice" % SDSettings.preset_name(preset))
		field.free()
	var mesh := DisplacementField3D.build_mesh(4, 16)
	var arrays := mesh.surface_get_arrays(0)
	var lattice: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var info: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var expected_vertices := 17 * 17 + 3 * (17 * 17 - 7 * 7)
	check(lattice.size() == expected_vertices, "4 rings of 16 x 16 quads: %d vertices (expected %d)" % [lattice.size(), expected_vertices])
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	check(indices.size() == 6 * (16 * 16 + 3 * (16 * 16 - 8 * 8)), "and 2 triangles per quad, none inside the holes")


## Replica of the shader's morph for a vertex forced to the ring's edge state.
static func _morphed(lattice: Vector2, level: float, m: float) -> Vector2:
	var step := pow(2.0, level)
	var odd := Vector2(fposmod(lattice.x / step, 2.0), fposmod(lattice.y / step, 2.0))
	return lattice - odd * step * m


func test_field_mesh_seams() -> void:
	print("\n== field seams")
	var n := 32
	var levels := 4
	var mesh := DisplacementField3D.build_mesh(levels, n)
	var arrays := mesh.surface_get_arrays(0)
	var lattice: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var info: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var ok := true
	var outer_count := 0
	for k in levels - 1:
		# Inner-edge vertices of ring k + 1 (unmorphed) and outer-edge vertices of ring k (m = 1).
		var coarse := {}
		for i in lattice.size():
			if int(info[i].x) == k + 1 and int(info[i].y) == 2:
				coarse[lattice[i]] = (lattice[i] / pow(2.0, k + 1)) + Vector2(0, 0)
		var fine_positions := {}
		for i in lattice.size():
			if int(info[i].x) == k and int(info[i].y) == 1:
				outer_count += 1
				var p := _morphed(lattice[i], k, 1.0)
				fine_positions[p] = true
				ok = ok and coarse.has(p)
		# Every coarse edge vertex is reached by the fine edge (no T-junction left open).
		for p: Vector2 in coarse:
			ok = ok and fine_positions.has(p)
	check(ok and outer_count > 0, "every ring's outer edge collapses exactly onto the next ring's inner-edge vertices (%d edge vertices)" % outer_count)
	var flagged_ok := true
	for i in lattice.size():
		var ring := maxf(absf(lattice[i].x), absf(lattice[i].y)) / pow(2.0, info[i].x)
		var k := int(info[i].x)
		if is_equal_approx(ring, n / 2.0) and k < levels - 1:
			flagged_ok = flagged_ok and int(info[i].y) == 1
		elif k > 0 and is_equal_approx(ring, n / 4.0):
			flagged_ok = flagged_ok and int(info[i].y) == 2
		else:
			flagged_ok = flagged_ok and int(info[i].y) == 0
	check(flagged_ok, "edge vertices carry the seam flags, all others none")


# --- Ground bake ---------------------------------------------------------------------------------

func test_ground_bake_sampling() -> void:
	print("
== ground bake sampling")
	# A linear ramp of 8 x 8 texels (0.1 m and 0.3 m per 0.5 m texel: below the 0.8 slope limit).
	var n := 8
	var heights := PackedFloat32Array()
	var layers := PackedInt32Array()
	for y in n:
		for x in n:
			heights.append(0.1 * x + 0.3 * y)
			layers.append(0)
	var bake := SDGroundBake.from_arrays(Vector2i(n, n), heights, layers, Vector2(-1.0, 2.0), 0.5)
	var ok := true
	var normal_ok := true
	for p: Vector2 in [Vector2(0.1, 3.3), Vector2(0.49, 3.49), Vector2(1.2, 4.1)]:
		var t := (p - bake.origin) / bake.texel_size - Vector2(0.5, 0.5)
		var s := bake.sample(p)
		ok = ok and absf(float(s["height"]) - (0.1 * t.x + 0.3 * t.y)) < 1e-4 and (s["weights"] as Color).r > 0.999
		normal_ok = normal_ok and (s["normal"] as Vector3).distance_to(Vector3(-0.2, 1.0, -0.6).normalized()) < 1e-3
	check(ok, "heights bilinear between texel centres (16-bit precision), layer 0 displaceable inside")
	check(normal_ok, "the normal follows the height's gradient")
	var corner := bake.origin + Vector2(0.25, 0.25)
	check(bake.sample_weights(corner).r < 1e-6 and bake.sample_weights(bake.origin + Vector2(-3.0, 1.0)).r < 1e-6,
			"nothing is displaceable at the bake's border texels or beyond the bake")
	# Beyond the right edge the height continues the edge column, bilinear along it.
	var beyond_ok := true
	for z: float in [3.3, 3.45, 4.1]:
		var tz := (z - bake.origin.y) / bake.texel_size - 0.5
		beyond_ok = beyond_ok and absf(bake.sample_height(Vector2(bake.origin.x + 12.0, z)) - (0.1 * (n - 1) + 0.3 * tz)) < 1e-4
	check(beyond_ok and absf(bake.sample_height(bake.origin + Vector2(20.0, 20.0)) - (0.1 * (n - 1) + 0.3 * (n - 1))) < 1e-4,
			"beyond the bake the height continues its edge smoothly")

	# Steps are judged by slope, whatever the texel size: at 5 cm texels (limit 4 cm) and at 20 cm
	# texels (limit 16 cm) a 30-degree slope stays ground and a 45-degree one does not. (A kerb
	# lower than the limit is draped: a 15 cm kerb is a step at 5 cm texels, not at 20 cm.)
	for texel: float in [0.05, 0.2]:
		var row := func(rise_per_texel: float) -> bool:
			var hs := PackedFloat32Array()
			var ls := PackedInt32Array()
			for y in 5:
				for x in 5:
					hs.append(rise_per_texel * x)
					ls.append(0)
			var b := SDGroundBake.from_arrays(Vector2i(5, 5), hs, ls, Vector2.ZERO, texel)
			return b.sample_weights(Vector2(2.5, 2.5) * texel).r > 0.999
		check(row.call(tan(deg_to_rad(30.0)) * texel) and not row.call(tan(deg_to_rad(45.0)) * texel),
				"%.2f m texels: a 30-degree slope is ground, a 45-degree slope is a step" % texel)
	var kerb := PackedFloat32Array()
	var kerb_layers := PackedInt32Array()
	for y in 5:
		for x in 8:
			kerb.append(0.15 if x >= 4 else 0.0)
			kerb_layers.append(0)
	var kb := SDGroundBake.from_arrays(Vector2i(8, 5), kerb, kerb_layers, Vector2.ZERO, 0.05)
	check(kb.sample_weights(Vector2(1.5, 2.5) * 0.05).r > 0.999 and kb.sample_weights(Vector2(3.5, 2.5) * 0.05).r < 1e-6
			and kb.sample_weights(Vector2(4.5, 2.5) * 0.05).r < 1e-6 and kb.sample_weights(Vector2(6.5, 2.5) * 0.05).r > 0.999,
			"texels on both sides of a 15 cm kerb lose their layer (the field dives there), the others keep it")

	# A cell without ground and a cell of ground that is none of the field's layers.
	var flat := PackedFloat32Array()
	var mixed := PackedInt32Array()
	for y in 7:
		for x in 7:
			flat.append(0.5)
			mixed.append(-2 if Vector2i(x, y) == Vector2i(3, 3) else (1 if x == 5 else 0))
	var hb := SDGroundBake.from_arrays(Vector2i(7, 7), flat, mixed, Vector2.ZERO, 0.1)
	check(hb.sample_weights(Vector2(0.35, 0.35)).r < 1e-6 and hb.sample_weights(Vector2(0.25, 0.35)).r < 1e-6
			and absf(hb.sample_height(Vector2(0.35, 0.35)) - 0.5) < 1e-4,
			"no ground: that cell and its neighbours are not displaceable, its height is its neighbours'")
	check(hb.sample_weights(Vector2(0.55, 0.15)).g > 0.999 and hb.sample_weights(Vector2(0.15, 0.15)).r > 0.999,
			"each cell carries the field layer its ground is")


# --- Demo textures ------------------------------------------------------------------------------

func test_demo_textures() -> void:
	print("\n== demo textures")
	var ok := true
	var count := 0
	for dir in DirAccess.get_directories_at("res://demo/textures"):
		for kind in ["height.exr", "albedo.jpg", "normal.jpg", "arm.jpg"]:
			var tex := load("res://demo/textures/%s/%s_%s" % [dir, dir, kind]) as Texture2D
			count += 1
			if tex == null or not tex.get_image().has_mipmaps():
				ok = false
				print("  no mipmaps: %s %s" % [dir, kind])
		var height := (load("res://demo/textures/%s/%s_height.exr" % [dir, dir]) as Texture2D).get_image()
		ok = ok and height.get_format() == Image.FORMAT_RH
	check(ok, "all %d demo textures are imported with mipmaps; heights are 16-bit float, one channel" % count)


# --- Node lifetime -------------------------------------------------------------------------------

func test_node_lifetime() -> void:
	print("\n== node lifetime")
	var scene := Builder.build(0)
	# No rendering device here (--headless): keep the field on its flat-ground fallback.
	(scene.find_children("*", "DisplacementField3D", true, false)[0] as DisplacementField3D).bake_on_ready = false
	root.add_child(scene)
	for i in 3:
		await process_frame
	var field := scene.find_children("*", "DisplacementField3D", true, false)[0] as DisplacementField3D
	check(field.get_mesh_instance() != null and field.get_mesh_instance().get_parent() == field, "the field owns its mesh as an internal child")
	check(field.get_children(true).has(field.get_mesh_instance()) and not field.get_children(false).has(field.get_mesh_instance()),
			"which is internal (never saved with the scene)")
	scene.queue_free()
	await process_frame
	await process_frame
	check(get_nodes_in_group(&"surface_displacement_field").is_empty() and get_nodes_in_group(&"surface_displacement_manager").is_empty(),
			"freeing the scene unregisters the field and the manager")
