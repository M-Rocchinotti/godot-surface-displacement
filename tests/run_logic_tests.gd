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
	await test_settings_changes()
	test_material_discovery()
	test_validator()
	test_field_geometry()
	test_field_mesh_seams()
	test_ground_bake_sampling()
	test_demo_textures()
	await test_node_lifetime()
	await test_scatter_parameter_sync()
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
	for m in GADSMaterials.MAPPING_NAMES.size():
		for q in GADSMaterials.QUALITY_NAMES.size():
			for depth in [false, true]:
				var path := GADSMaterials.variant_path(m, q, depth)
				var shader := load(path) as Shader
				if shader == null:
					ok = false
					print("  missing variant %s" % path)
					continue
				count += 1
				var info := GADSMaterials.parse(shader)
				var want_depth: bool = depth and q != GADSMaterials.Quality.FLAT
				ok = ok and info.get("mapping") == m and info.get("quality") == q and info.get("depth_write") == want_depth
				# Each variant defines exactly what its name says (the generator is the source).
				var code := shader.code
				ok = ok and code.contains("#define GADS_POM") == (q != GADSMaterials.Quality.FLAT)
				ok = ok and code.contains("#define GADS_SELF_SHADOW") == (q == GADSMaterials.Quality.POM_SELF_SHADOW)
				ok = ok and code.contains("#define GADS_DEPTH_WRITE") == want_depth
	check(ok, "every mapping x quality x depth variant exists, parses back and defines what its name says (%d loaded)" % count)
	check(GADSMaterials.parse(null).is_empty() and not GADSMaterials.is_gads_material(StandardMaterial3D.new()), "other shaders and materials are not taken for GADS variants")
	var mat := GADSMaterials.create(GADSMaterials.Mapping.UV, {}, {"height_m": 0.02}, GADSMaterials.Quality.POM, true)
	GADSMaterials.set_quality(mat, GADSMaterials.Quality.FLAT)
	var flat_info := GADSMaterials.parse(mat.shader)
	GADSMaterials.set_quality(mat, GADSMaterials.Quality.POM_SELF_SHADOW)
	var back := GADSMaterials.parse(mat.shader)
	check(flat_info["quality"] == GADSMaterials.Quality.FLAT and back["depth_write"] == true and back["quality"] == GADSMaterials.Quality.POM_SELF_SHADOW,
			"the opt-in depth write survives a switch to flat and back")
	check(is_equal_approx(float(mat.get_shader_parameter("height_m")), 0.02), "switching variants keeps the material's parameters")
	GADSMaterials.set_depth_write(mat, false)
	GADSMaterials.set_quality(mat, GADSMaterials.Quality.FLAT)
	GADSMaterials.set_quality(mat, GADSMaterials.Quality.POM)
	check(not GADSMaterials.parse(mat.shader)["depth_write"], "opting out of the depth write sticks")


# --- Presets -----------------------------------------------------------------------------------

func test_presets() -> void:
	print("\n== presets")
	var off := GADSSettings.create_preset(GADSSettings.Preset.OFF)
	var low := GADSSettings.create_preset(GADSSettings.Preset.LOW)
	var med := GADSSettings.create_preset(GADSSettings.Preset.MEDIUM)
	var high := GADSSettings.create_preset(GADSSettings.Preset.HIGH)
	var ultra := GADSSettings.create_preset(GADSSettings.Preset.ULTRA)
	check(off.get_quality() == GADSMaterials.Quality.FLAT and low.get_quality() == GADSMaterials.Quality.POM
			and med.get_quality() == GADSMaterials.Quality.POM_SELF_SHADOW, "Off = flat, Low = POM, Medium and up = POM with self-shadowing")
	check(not low.near_field_enabled and not med.near_field_enabled and not high.near_field_enabled and ultra.near_field_enabled,
			"near-camera geometry only at Ultra")
	check(ultra.scatter_enabled and not high.scatter_enabled, "pebble scatter only at Ultra")
	check(low.pom_max_steps <= med.pom_max_steps and med.pom_max_steps <= high.pom_max_steps and low.pom_fade_end <= med.pom_fade_end
			and med.pom_fade_end <= high.pom_fade_end and low.pom_refine_steps < med.pom_refine_steps and med.pom_refine_steps <= high.pom_refine_steps
			and high.self_shadow == GADSSettings.SelfShadow.SOFT and med.self_shadow == GADSSettings.SelfShadow.HARD,
			"steps, fade distance, refinement and self-shadow quality grow from Low to High")
	check(ultra.self_shadow == GADSSettings.SelfShadow.SOFT and ultra.pom_max_steps >= med.pom_max_steps and ultra.pom_fade_end >= med.pom_fade_end
			and ultra.pom_refine_steps >= med.pom_refine_steps and ultra.self_shadow_steps >= med.self_shadow_steps,
			"Ultra keeps soft self-shadowing and at least Medium's parallax next to its geometry")
	check(high.self_shadow_local_lights and ultra.self_shadow_local_lights and not med.self_shadow_local_lights and not low.self_shadow_local_lights,
			"omni and spot lights self-shadow from High up")
	var budgets := [0.5, 1.2, 2.0, 3.0]
	var ok := true
	for p in 4:
		ok = ok and is_equal_approx(GADSSettings.get_budget_ms(p + 1), budgets[p])
	check(ok, "budgets 0.5 / 1.2 / 2.0 / 3.0 ms for Low / Medium / High / Ultra")


# --- GADSManager node ----------------------------------------------------------------

func test_manager() -> void:
	print("\n== GADSManager node")
	var scene := Node3D.new()
	var gads := GADSManager.new()
	gads.preset = GADSSettings.Preset.HIGH
	scene.add_child(gads)
	var mat := GADSMaterials.create(GADSMaterials.Mapping.WORLD, {}, {}, GADSMaterials.Quality.POM)
	var mi := MeshInstance3D.new()
	mi.mesh = PlaneMesh.new()
	mi.material_override = mat
	scene.add_child(mi)
	root.add_child(scene)
	gads.apply()
	check(GADSMaterials.parse(mat.shader)["quality"] == GADSMaterials.Quality.POM_SELF_SHADOW, "materials in the scene switch to the preset's variant")
	check(GADSManager.find_in(self) == gads, "find_in() finds the node")
	gads.set_feature(GADSManager.Feature.SELF_SHADOW, false)
	gads.apply()
	check(GADSMaterials.parse(mat.shader)["quality"] == GADSMaterials.Quality.POM, "switching self-shadowing off selects the POM variant")
	gads.set_feature(GADSManager.Feature.POM, false)
	gads.apply()
	check(GADSMaterials.parse(mat.shader)["quality"] == GADSMaterials.Quality.FLAT and not gads.is_feature_active(GADSManager.Feature.SELF_SHADOW),
			"switching POM off selects the flat variant and implies no self-shadowing")
	gads.pom = true
	gads.self_shadow = true
	gads.preset = GADSSettings.Preset.LOW
	gads.near_field = true
	gads.apply()
	check(not gads.is_feature_active(GADSManager.Feature.NEAR_FIELD), "a feature switch cannot add what the preset leaves out")
	gads.preset = GADSSettings.Preset.ULTRA
	gads.near_field = false
	gads.apply()
	check(not gads.is_feature_active(GADSManager.Feature.SCATTER), "pebble scatter needs the near-camera geometry")
	var late := GADSMaterials.create(GADSMaterials.Mapping.UV, {}, {}, GADSMaterials.Quality.FLAT)
	var mi2 := MeshInstance3D.new()
	mi2.mesh = PlaneMesh.new()
	mi2.material_override = late
	scene.add_child(mi2)
	check(GADSMaterials.parse(late.shader)["quality"] == GADSMaterials.Quality.POM_SELF_SHADOW, "materials added later are switched as they enter the tree")
	gads.enabled = false
	gads.apply()
	check(GADSMaterials.parse(mat.shader)["quality"] == GADSMaterials.Quality.FLAT and is_zero_approx(gads.get_budget_ms()), "enabled = false draws everything flat")
	scene.queue_free()


## Presets reach GADS materials wherever a scene draws them, not only on MeshInstance3D surfaces.
func test_material_discovery() -> void:
	print("\n== materials on every kind of geometry")
	var scene := Node3D.new()
	var gads := GADSManager.new()
	gads.preset = GADSSettings.Preset.HIGH
	scene.add_child(gads)
	var made := {}
	var flat := func(label: String) -> ShaderMaterial:
		made[label] = GADSMaterials.create(GADSMaterials.Mapping.TRIPLANAR, {}, {}, GADSMaterials.Quality.FLAT)
		return made[label]
	var box := BoxMesh.new()
	box.material = flat.call("mesh surface")
	var mi := MeshInstance3D.new()
	mi.mesh = box
	mi.material_overlay = flat.call("material_overlay")
	scene.add_child(mi)
	var chained := StandardMaterial3D.new()
	chained.next_pass = flat.call("next_pass")
	var mi2 := MeshInstance3D.new()
	mi2.mesh = SphereMesh.new()
	mi2.material_override = chained
	scene.add_child(mi2)
	var csg := CSGBox3D.new()
	csg.material = flat.call("CSG shape")
	scene.add_child(csg)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	var multimesh_mesh := PlaneMesh.new()
	multimesh_mesh.material = flat.call("MultiMesh")
	multimesh.mesh = multimesh_mesh
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = multimesh
	scene.add_child(mmi)
	var library := MeshLibrary.new()
	var tile := PlaneMesh.new()
	tile.material = flat.call("GridMap")
	library.create_item(0)
	library.set_item_mesh(0, tile)
	var grid := GridMap.new()
	grid.mesh_library = library
	scene.add_child(grid)
	var particles := GPUParticles3D.new()
	var pass_mesh := QuadMesh.new()
	pass_mesh.material = flat.call("GPUParticles3D")
	particles.draw_pass_1 = pass_mesh
	scene.add_child(particles)
	root.add_child(scene)
	# Added after the node is ready: picked up as it enters the tree.
	var late := CSGCylinder3D.new()
	late.material = flat.call("CSG shape added later")
	scene.add_child(late)
	var missed: Array[String] = []
	for label: String in made:
		if GADSMaterials.parse((made[label] as ShaderMaterial).shader)["quality"] != GADSMaterials.Quality.POM_SELF_SHADOW:
			missed.append(label)
	check(missed.is_empty(), "the preset reaches GADS materials on mesh surfaces, overlays, next passes, CSG shapes, MultiMeshes, GridMaps and particles%s"
			% ("" if missed.is_empty() else " (missed: %s)" % ", ".join(missed)))
	scene.queue_free()


## Validate Setup reports each setup mistake it knows, and nothing on a correct setup.
func test_validator() -> void:
	print("\n== Validate Setup")
	var height := ImageTexture.create_from_image(Image.create(8, 8, true, Image.FORMAT_RH))
	var good := Node3D.new()
	var gads := GADSManager.new()
	good.add_child(gads)
	var ground_mat := GADSMaterials.create(GADSMaterials.Mapping.WORLD, {"height": height}, {"height_center": 0.0})
	var ground := MeshInstance3D.new()
	ground.mesh = PlaneMesh.new()
	ground.material_override = ground_mat
	ground.add_to_group(&"gads_ground_validator")
	good.add_child(ground)
	var field := GADSDisplacementField3D.new()
	field.bake_on_ready = false
	field.ground_group = &"gads_ground_validator"
	field.layers = [ground_mat]
	field.add_child(GADSPebbleScatter3D.new())
	good.add_child(field)
	root.add_child(good)
	var clean := GADSValidator.validate(good).filter(func(i: Dictionary) -> bool: return i["level"] != "info")
	for i: Dictionary in clean:
		print("  unexpected: %s" % i["message"])
	check(clean.is_empty(), "a correct setup gets no errors or warnings")
	good.queue_free()

	var bad := Node3D.new()
	var custom := GADSManager.new()
	custom.preset = GADSSettings.Preset.CUSTOM
	bad.add_child(custom)
	bad.add_child(GADSPebbleScatter3D.new())
	# A UV-mapped material on a mesh without UVs, and the same on one with UVs.
	var uv_mat := GADSMaterials.create(GADSMaterials.Mapping.UV, {"height": height}, {"height_m": 0.0, "height_remap": Vector2(0.4, 0.4)})
	for with_uv in [false, true]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for v in [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 0, 1)]:
			st.set_normal(Vector3.UP)
			if with_uv:
				st.set_uv(Vector2(v.x, v.z))
			st.add_vertex(v)
		var mi := MeshInstance3D.new()
		mi.name = "WithUV" if with_uv else "NoUV"
		mi.mesh = st.commit()
		mi.material_override = uv_mat
		bad.add_child(mi)
	var layer := GADSMaterials.create(GADSMaterials.Mapping.WORLD, {"height": height}, {"height_center": 0.0})
	var other_ground := GADSMaterials.create(GADSMaterials.Mapping.WORLD, {"height": height}, {"height_center": 0.0})
	other_ground.resource_name = "other_ground"
	var ground2 := MeshInstance3D.new()
	ground2.mesh = PlaneMesh.new()
	ground2.material_override = other_ground
	ground2.add_to_group(&"gads_ground_validator")
	bad.add_child(ground2)
	var many := GADSDisplacementField3D.new()
	many.bake_on_ready = false
	many.ground_group = &"gads_ground_validator"
	many.layers = [layer, layer, layer, layer, layer]
	var stale := GADSGroundBake.new()
	stale.layer_names = PackedStringArray(["res://some_other_layer.tres"])
	many.ground_bake = stale
	bad.add_child(many)
	root.add_child(bad)
	var messages := "\n".join(GADSValidator.validate(bad).map(func(i: Dictionary) -> String: return i["message"]))
	var expected := {
		"Custom preset without settings": "preset Custom without custom_settings",
		"pebble scatter outside a field": "must be a child of a GADSDisplacementField3D",
		"UV mapping on a mesh without UVs": "NoUV, surface 0: UV-mapped GADS material on a mesh without UVs",
		"height_m 0": "height_m 0: it draws flat",
		"a degenerate height_remap": "maps every height to the same value",
		"more than four layers": "only the first 4 are used",
		"a bake made for other layers": "its ground bake was made for other layers",
		"ground the field leaves flat": "ground material other_ground is not one of its layers",
	}
	var missing: Array[String] = []
	for what: String in expected:
		if not messages.contains(expected[what]):
			missing.append(what)
	check(missing.is_empty(), "it reports %s%s" % [", ".join(expected.keys()), "" if missing.is_empty() else " (missing: %s)" % ", ".join(missing)])
	check(not messages.contains("WithUV"), "a UV-mapped material on a mesh with UVs is not reported")
	bad.queue_free()


## Edits to a Custom preset's settings resource apply without touching the node, and the local
## lights' self-shadow flag reaches the shaders only where self-shadowing is on.
func test_settings_changes() -> void:
	print("\n== settings changes")
	var scene := Node3D.new()
	var gads := GADSManager.new()
	var custom := GADSSettings.create_preset(GADSSettings.Preset.MEDIUM)
	gads.custom_settings = custom
	gads.preset = GADSSettings.Preset.CUSTOM
	scene.add_child(gads)
	root.add_child(scene)
	await process_frame
	custom.pom_max_steps = 37
	custom.self_shadow_local_lights = true
	await process_frame
	await process_frame
	var steps: Vector4 = GADSGlobals.get_value(GADSGlobals.POM_STEPS)
	check(int(steps.y) == 37 and is_equal_approx(steps.w, 1.0), "a value changed on custom_settings applies at the end of the frame")
	gads.custom_settings = GADSSettings.create_preset(GADSSettings.Preset.LOW)
	await process_frame
	custom.pom_max_steps = 50
	await process_frame
	await process_frame
	check(int((GADSGlobals.get_value(GADSGlobals.POM_STEPS) as Vector4).y) == 10, "a replaced settings resource no longer drives the node")
	gads.preset = GADSSettings.Preset.HIGH
	gads.apply()
	var high_w := (GADSGlobals.get_value(GADSGlobals.POM_STEPS) as Vector4).w
	gads.self_shadow = false
	gads.apply()
	var no_shadow_w := (GADSGlobals.get_value(GADSGlobals.POM_STEPS) as Vector4).w
	gads.self_shadow = true
	gads.preset = GADSSettings.Preset.MEDIUM
	gads.apply()
	var medium_w := (GADSGlobals.get_value(GADSGlobals.POM_STEPS) as Vector4).w
	check(is_equal_approx(high_w, 1.0) and is_zero_approx(no_shadow_w) and is_zero_approx(medium_w),
			"omni and spot lights self-shadow at High, not at Medium and not with self-shadowing switched off")
	scene.queue_free()
	await process_frame


# --- GADSDisplacementField3D geometry ------------------------------------------------------------

func test_field_geometry() -> void:
	print("\n== field geometry")
	# Ultra's field, a node with its defaults, and a dense grid (4 rings of 256 at 1.5 cm).
	var dense := GADSSettings.create_preset(GADSSettings.Preset.ULTRA)
	dense.near_field_levels = 4
	dense.near_field_resolution = 256
	dense.near_field_spacing = 0.015
	var defaults := GADSDisplacementField3D.new()
	var configs := {"Ultra": GADSSettings.create_preset(GADSSettings.Preset.ULTRA), "dense": dense}
	check(defaults.levels == configs["Ultra"].near_field_levels and defaults.resolution == configs["Ultra"].near_field_resolution
			and is_equal_approx(defaults.base_spacing, configs["Ultra"].near_field_spacing), "a new field's defaults are Ultra's grid")
	defaults.free()
	for config_name: String in configs:
		var s: GADSSettings = configs[config_name]
		var field := GADSDisplacementField3D.new()
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
		check(ok, "%s: morph bands fit inside their rings and the relief fades out inside the grid (reach %.1f m, snap %.2f m)" % [config_name, field.get_reach(), field.get_snap()])
		var o := field.snapped_origin(Vector3(1.234, 5.0, -7.777))
		check(is_zero_approx(fposmod(o.x, field.get_snap())) or is_equal_approx(fposmod(o.x, field.get_snap()), field.get_snap()),
				"%s: the origin snaps to the coarsest lattice" % config_name)
		field.free()
	var mesh := GADSDisplacementField3D.build_mesh(4, 16)
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
	var mesh := GADSDisplacementField3D.build_mesh(levels, n)
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
	print("\n== ground bake sampling")
	# A linear ramp of 8 x 8 texels (0.1 m and 0.3 m per 0.5 m texel: below the 0.8 slope limit).
	var n := 8
	var heights := PackedFloat32Array()
	var layers := PackedInt32Array()
	for y in n:
		for x in n:
			heights.append(0.1 * x + 0.3 * y)
			layers.append(0)
	var bake := GADSGroundBake.from_arrays(Vector2i(n, n), heights, layers, Vector2(-1.0, 2.0), 0.5)
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
			var b := GADSGroundBake.from_arrays(Vector2i(5, 5), hs, ls, Vector2.ZERO, texel)
			return b.sample_weights(Vector2(2.5, 2.5) * texel).r > 0.999
		check(row.call(tan(deg_to_rad(30.0)) * texel) and not row.call(tan(deg_to_rad(45.0)) * texel),
				"%.2f m texels: a 30-degree slope is ground, a 45-degree slope is a step" % texel)
	var kerb := PackedFloat32Array()
	var kerb_layers := PackedInt32Array()
	for y in 5:
		for x in 8:
			kerb.append(0.15 if x >= 4 else 0.0)
			kerb_layers.append(0)
	var kb := GADSGroundBake.from_arrays(Vector2i(8, 5), kerb, kerb_layers, Vector2.ZERO, 0.05)
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
	var hb := GADSGroundBake.from_arrays(Vector2i(7, 7), flat, mixed, Vector2.ZERO, 0.1)
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
	(scene.find_children("*", "GADSDisplacementField3D", true, false)[0] as GADSDisplacementField3D).bake_on_ready = false
	root.add_child(scene)
	for i in 3:
		await process_frame
	var field := scene.find_children("*", "GADSDisplacementField3D", true, false)[0] as GADSDisplacementField3D
	check(field.get_mesh_instance() != null and field.get_mesh_instance().get_parent() == field, "the field owns its mesh as an internal child")
	check(field.get_children(true).has(field.get_mesh_instance()) and not field.get_children(false).has(field.get_mesh_instance()),
			"which is internal (never saved with the scene)")
	scene.queue_free()
	await process_frame
	await process_frame
	check(get_nodes_in_group(&"gads_field").is_empty() and get_nodes_in_group(&"gads_manager").is_empty(),
			"freeing the scene unregisters the field and the manager")


# --- Field parameters reach the pebbles, once ----------------------------------------------------

## GADSPebbleScatter3D copies the field's ground and layer parameters. Setting a texture parameter
## makes the renderer rebuild the material's uniform set, so the copy must happen when the field
## changes them, not every frame; and a change must still arrive.
func test_scatter_parameter_sync() -> void:
	print("\n== field parameters reach the pebble scatter")
	var scene := Node3D.new()
	var cam := Camera3D.new()
	scene.add_child(cam)
	var height := ImageTexture.create_from_image(Image.create(8, 8, true, Image.FORMAT_RH))
	var layer := GADSMaterials.create(GADSMaterials.Mapping.WORLD, {"height": height}, {"height_m": 0.03, "height_center": 0.0})
	var field := GADSDisplacementField3D.new()
	field.bake_on_ready = false
	field.layers = [layer]
	var pebbles := GADSPebbleScatter3D.new()
	field.add_child(pebbles)
	scene.add_child(field)
	root.add_child(scene)
	cam.current = true
	for i in 3:
		await process_frame
	var process_material := pebbles.get_particles().process_material as ShaderMaterial
	var version := field.get_parameters_version()
	check(version > 0 and process_material.get_shader_parameter("layer_height") == field.get_material().get_shader_parameter("layer_height"),
			"the scatter has the field's layer textures")
	cam.position = Vector3(1.3, 1.7, -2.1)
	for i in 5:
		await process_frame
	check(field.get_parameters_version() == version, "a moving camera changes no ground or layer parameter (version %d -> %d)"
			% [version, field.get_parameters_version()])
	# The editor re-applies the layers every 30 frames in case they were edited.
	field.sync_layers()
	for i in 2:
		await process_frame
	check(field.get_parameters_version() == version, "re-applying unchanged layers sets no parameter (version %d -> %d)"
			% [version, field.get_parameters_version()])
	layer.set_shader_parameter("height_m", 0.05)
	field.sync_layers()
	for i in 2:
		await process_frame
	var layer_a: Array = process_material.get_shader_parameter("layer_a")
	check(field.get_parameters_version() > version and is_equal_approx((layer_a[0] as Vector4).x, 0.05),
			"a changed layer parameter reaches the scatter")
	scene.queue_free()
	await process_frame
