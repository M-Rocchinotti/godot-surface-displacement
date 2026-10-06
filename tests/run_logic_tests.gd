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
	test_height_analysis()
	test_deformation_field()
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
	await test_terrain_validation()
	test_texture_sets()
	test_mesh_diagnostics()
	test_procedural()
	await test_adaptive_quality()
	await test_platform_caps()
	test_sculpt_brush()
	test_erosion()
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

## GADSDeformationField on the CPU: stamps, combine modes, rims, strokes, image stamps, the
## window following its target, persistence and the shader globals.
func test_deformation_field() -> void:
	print("\n== deformation field")
	var holder := Node3D.new()
	root.add_child(holder)
	var target := Node3D.new()
	holder.add_child(target)
	var f := GADSDeformationField.new()
	f.size_m = 8.0
	f.resolution = 256
	f.max_depth = 0.3
	holder.add_child(f)
	f.follow = f.get_path_to(target)
	f._process(0.0)
	var t := f.get_texel_size()
	check(f.get_window_rect().position == Vector2(-4, -4) and is_equal_approx(t, 8.0 / 256.0), "the window centres on its target")
	var at := func(x: float, z: float) -> float: return f.get_depth(Vector3(x, 0, z))
	f.stamp(Vector3(1, 0, 1), 0.2, 0.05)
	check(absf(at.call(1.0, 1.0) - 0.05) < 0.002 and at.call(1.25, 1.0) == 0.0, "a round mark is its depth in the middle and 0 beyond its radius")
	f.stamp(Vector3(1, 0, 1), 0.2, 0.05)
	check(absf(at.call(1.0, 1.0) - 0.05) < 0.002, "DEEPEN: stepping twice does not dig deeper")
	for i in 10:
		f.stamp(Vector3(1, 0, 1), 0.2, 0.05, 0.0, GADSDeformationField.Combine.ADD)
	check(is_equal_approx(at.call(1.0, 1.0), 0.3), "ADD digs deeper, down to max_depth")
	f.stamp(Vector3(-1, 0, -1), 0.2, 0.04, 0.01)
	check(at.call(-1.0 + 0.25, -1.0) < -0.005, "a rim pushes the ground up around a mark")
	f.stroke(Vector3(-2, 0, 2), Vector3(2, 0, 2), 0.2, 0.03)
	check(absf(at.call(0.0, 2.0) - 0.03) < 0.002 and at.call(0.0, 2.15) == 0.0, "a stroke presses a track along its line")
	var foot := Image.create(8, 8, false, Image.FORMAT_RF)
	foot.fill_rect(Rect2i(0, 0, 8, 4), Color(1, 0, 0)) # front half
	f.stamp_image(Vector3(-2, 0, -2), foot, Vector2(0.4, 0.4), 0.0, 0.02)
	check(absf(at.call(-2.0, -2.0 + 0.1) - 0.02) < 0.002 and at.call(-2.0, -2.0 - 0.1) == 0.0,
			"an image stamp's top row points along its heading (+Z here)")
	# The window moves with its target: marks inside both windows stay, marks that leave are cleared.
	f.stamp(Vector3(3, 0, 0), 0.2, 0.05)
	target.position.x = 2.0
	f._process(0.0)
	check(absf(at.call(3.0, 0.0) - 0.05) < 0.002, "a mark stays while the window moves over it")
	target.position.x = 8.0
	f._process(0.0)
	target.position.x = 0.0
	f._process(0.0)
	check(at.call(3.0, 0.0) == 0.0 and at.call(-1.0, -1.0) == 0.0, "marks that left the window are cleared")
	f.stamp(Vector3(0.5, 0, 0.5), 0.2, 0.07)
	var state := f.get_state()
	f.clear()
	check(at.call(0.5, 0.5) == 0.0, "clear() removes every mark")
	check(f.set_state(state) and absf(at.call(0.5, 0.5) - 0.07) < 0.002, "get_state() / set_state() bring the marks back")
	var params: Vector4 = GADSGlobals.get_value(GADSGlobals.DEFORM_PARAMS)
	check(params == Vector4(-4, -4, 8, 0.3) and GADSGlobals.get_value(GADSGlobals.DEFORM) == f.get_texture(),
			"the field publishes its texture, window and depth to the shaders")
	holder.queue_free()


## GADSHeightTools.analyse_detail(): how much relief each scale of a height map carries.
func test_height_analysis() -> void:
	print("\n== height map analysis")
	var flat := Image.create(256, 256, false, Image.FORMAT_RF)
	flat.fill(Color(0.5, 0, 0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	var noise := Image.create(256, 256, false, Image.FORMAT_RF)
	for y in 256:
		for x in 256:
			noise.set_pixel(x, y, Color(rng.randf(), 0, 0))
	# Smooth relief at 64 px, enlarged to 256: the extra texels hold no relief.
	var smooth := Image.create(64, 64, false, Image.FORMAT_RF)
	for y in 64:
		for x in 64:
			smooth.set_pixel(x, y, Color(0.5 + 0.4 * sin(x * TAU / 16.0) * cos(y * TAU / 16.0), 0, 0))
	smooth.resize(256, 256, Image.INTERPOLATE_BILINEAR)
	var a_flat := GADSHeightTools.analyse_detail(flat)
	var a_noise := GADSHeightTools.analyse_detail(noise)
	var a_smooth := GADSHeightTools.analyse_detail(smooth)
	print("  useful size: flat %d, noise %d, 64 px relief enlarged to 256 %d; finest-band share: noise %.2f, smooth %.3f" % [
		a_flat["useful_size"], a_noise["useful_size"], a_smooth["useful_size"], a_noise["fine_fraction"], a_smooth["fine_fraction"]])
	check(a_noise["useful_size"] == 256 and a_noise["fine_fraction"] > 0.3, "noise holds relief down to its finest texels")
	check(a_smooth["useful_size"] <= 128 and a_smooth["fine_fraction"] < 0.05, "an enlarged map is reported as larger than its relief needs")
	check(a_flat["fine_fraction"] == 0.0, "a flat map has no relief at any scale")


func test_variants() -> void:
	print("\n== shader variants")
	var count := 0
	var ok := true
	for layered in [false, true]:
		for m in GADSMaterials.MAPPING_NAMES.size():
			for q in GADSMaterials.QUALITY_NAMES.size():
				for depth in [false, true]:
					var path := GADSMaterials.variant_path(m, q, depth, layered)
					var shader := load(path) as Shader
					if shader == null:
						ok = false
						print("  missing variant %s" % path)
						continue
					count += 1
					var info := GADSMaterials.parse(shader)
					var want_depth: bool = depth and q != GADSMaterials.Quality.FLAT
					ok = ok and info.get("mapping") == m and info.get("quality") == q and info.get("depth_write") == want_depth
					ok = ok and info.get("layered") == layered
					# Each variant defines exactly what its name says (the generator is the source).
					var code := shader.code
					ok = ok and code.contains("#define GADS_POM") == (q != GADSMaterials.Quality.FLAT)
					ok = ok and code.contains("#define GADS_SELF_SHADOW") == (q == GADSMaterials.Quality.POM_SELF_SHADOW)
					ok = ok and code.contains("#define GADS_DEPTH_WRITE") == want_depth
					ok = ok and code.contains("#define GADS_LAYERED") == layered
	check(ok, "every layering x mapping x quality x depth variant exists, parses back and defines what its name says (%d loaded)" % count)
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
	gads.set_weather(0.25, 0.5, 0.75)
	check(GADSGlobals.get_value(GADSGlobals.WEATHER) == Vector4(0.25, 0.5, 0.75, 0.0), "set_weather() sets the weather global")
	gads.set_weather(0.0, 0.0, 0.0)
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
	var detail_without_map := MeshInstance3D.new()
	detail_without_map.mesh = PlaneMesh.new()
	detail_without_map.material_override = GADSMaterials.create(GADSMaterials.Mapping.UV, {"height": height}, {"detail_height_m": 0.01})
	bad.add_child(detail_without_map)
	var empty_bake := GADSMeshInstance3D.new()
	empty_bake.name = "EmptyBake"
	bad.add_child(empty_bake)
	# A signed vector map stored in 8 bits, on a node that does not bake.
	var vdm := Image.create(4, 4, false, Image.FORMAT_RGB8)
	var vector_only := MeshInstance3D.new()
	vector_only.name = "VectorOnly"
	vector_only.mesh = PlaneMesh.new()
	vector_only.material_override = GADSMaterials.create(GADSMaterials.Mapping.UV, {"vector_displacement": ImageTexture.create_from_image(vdm)},
		{"vector_displacement_m": 0.02, "vector_displacement_signed": true})
	bad.add_child(vector_only)
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
		"a detail depth without a detail map": "detail_height_m is set but there is no detail_height_texture",
		"a GADSMeshInstance3D without a source mesh": "GADSMeshInstance3D EmptyBake cannot be baked: no source mesh",
		"a vector map on a node that does not bake": "moves vertices only in a GADSMeshInstance3D bake; VectorOnly draws without it",
		"a signed vector map in 8 bits": "vector_displacement_signed is on but the texture is 8-bit",
		"a vector map without a height map": "its bake follows the vector map, the parallax fallback draws flat",
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


## The terrain demo validates clean, and the validator catches a terrain's mistakes.
func test_terrain_validation() -> void:
	print("\n== terrain validation")
	var scene := Builder.build(4)
	root.add_child(scene)
	await process_frame
	var bad := []
	for i: Dictionary in GADSValidator.validate(scene):
		if i["level"] != "info":
			bad.append(i["message"])
	check(bad.is_empty(), "the terrain demo has no errors or warnings %s" % [bad])
	var t := scene.get_node("Terrain") as GADSTerrain3D
	var uv := GADSMaterials.create(GADSMaterials.Mapping.UV, {}, {"height_m": 0.02})
	var raised := GADSMaterials.create(GADSMaterials.Mapping.WORLD, {}, {"height_m": 0.02, "height_center": 1.0})
	t.layers = [raised, uv] as Array[ShaderMaterial]
	t.rotation_degrees = Vector3(0, 30, 0)
	var messages := []
	for i: Dictionary in GADSValidator.validate(scene):
		messages.append(i["message"])
	var text := "\n".join(messages)
	check(text.contains("not world-planar") and text.contains("height_center 1.00") and text.contains("rotated or scaled"),
		"a UV layer, a layer whose relief sits below and a rotated terrain are reported")
	scene.queue_free()
	await process_frame


## GADSTextureSet: texture sets and file roles from their names, the proposed parameters, the
## packed ORM and the flipped DirectX normal map.
func test_texture_sets() -> void:
	print("\n== texture sets")
	var dir := "user://gads_texset_test"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var grey := func(v: float) -> Image:
		var img := Image.create(16, 16, false, Image.FORMAT_L8)
		img.fill(Color(v, v, v))
		return img
	var height := Image.create(16, 16, false, Image.FORMAT_L8)
	for y in 16:
		for x in 16:
			var v := 0.2 + 0.6 * x / 15.0
			height.set_pixel(x, y, Color(v, v, v))
	var normal := Image.create(16, 16, false, Image.FORMAT_RGB8)
	normal.fill(Color8(128, 64, 255))
	var files := {
		"rocks_ground_05_diff_2k.png": grey.call(0.5), "rocks_ground_05_nor_gl_2k.png": normal, "rocks_ground_05_nor_dx_2k.png": normal,
		"rocks_ground_05_rough_2k.png": grey.call(0.25), "rocks_ground_05_disp_2k.png": height, "rocks_ground_05_ao_2k.png": grey.call(0.5),
		"Rock_BaseColor.png": grey.call(0.5), "Rock_Normal.png": normal, "Rock_Height.png": height, "Rock_OcclusionRoughnessMetallic.png": normal,
		"Rock_preview.png": grey.call(0.1), "Brick_Albedo.png": grey.call(0.5), "Brick_Normal_DX.png": normal,
	}
	var paths := PackedStringArray()
	for f: String in files:
		(files[f] as Image).save_png(ProjectSettings.globalize_path(dir.path_join(f)))
		paths.append(dir.path_join(f))
	paths.append(dir.path_join("readme.txt"))
	var sets := {}
	for s: Dictionary in GADSTextureSet.detect(paths):
		sets[s["name"]] = s
	check(sets.keys().size() == 3 and sets.has("rocks_ground_05") and sets.has("rock") and sets.has("brick"),
		"three sets by name: %s" % [sets.keys()])
	var ph: Dictionary = sets.get("rocks_ground_05", {"files": {}})
	var roles: Array = (ph["files"] as Dictionary).keys()
	roles.sort()
	check(roles == ["albedo", "ao", "height", "normal", "roughness"] and String(ph["files"]["normal"]).contains("nor_gl") and not ph["normal_dx"],
		"Poly Haven names: every role, the OpenGL normal map preferred (%s)" % [roles])
	var sub: Dictionary = sets.get("rock", {"files": {}})
	check((sub["files"] as Dictionary).has("orm") and (sub["files"] as Dictionary).has("albedo") and not (sub["files"] as Dictionary).values().has(dir.path_join("Rock_preview.png")),
		"Substance names: BaseColor, OcclusionRoughnessMetallic; an unknown role is left out")
	check(sets.get("brick", {}).get("normal_dx", false), "a DirectX normal map is recognised")
	var rec := GADSTextureSet.recommend(ph)
	print("  recommended %s" % rec)
	check(is_equal_approx(rec["height_m"], 0.07) and absf(rec["height_remap"].x - 0.2) < 0.03 and absf(rec["height_remap"].y - 0.8) < 0.03
		and (rec["notes"] as Array).size() == 1, "7 cm for a 2 m texture, the height remap from its percentiles, a note on its 8 bits")
	var orm := GADSTextureSet.pack_orm(ph["files"]["ao"], ph["files"]["roughness"], "")
	var px := orm.get_pixel(3, 3) if orm != null else Color()
	check(orm != null and absf(px.r - 0.5) < 0.01 and absf(px.g - 0.25) < 0.01 and px.b == 0.0, "ORM packs AO, roughness and metallic (none: 0)")
	var use := GADSTextureSet.prepare(sets["brick"])
	var flipped := Image.load_from_file(ProjectSettings.globalize_path(use.get("normal", "")))
	check(String(use.get("normal", "")).ends_with("brick_gads_normal.png") and flipped != null and flipped.get_pixel(0, 0).g8 == 191,
		"a DirectX normal map is written with its green channel flipped")
	use = GADSTextureSet.prepare(ph)
	var exr := Image.load_from_file(ProjectSettings.globalize_path(use.get("height", "")))
	check(exr != null and exr.get_format() == Image.FORMAT_RH and exr.get_pixel(0, 0).r < 0.02 and exr.get_pixel(15, 0).r > 0.98
		and String(use.get("orm", "")).ends_with("_gads_orm.png") and FileAccess.file_exists(String(use.get("orm", "")) + ".import"),
		"prepare writes the remapped 16-bit height and the packed ORM with their import settings")
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir.path_join(f)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))


## GADSMeshDiagnostics: the edges that matter for displacement, by kind, on meshes whose answer is
## known.
func test_mesh_diagnostics() -> void:
	print("\n== mesh diagnostics")
	var box := GADSMeshDiagnostics.analyse(BoxMesh.new())
	var c: Dictionary = box["counts"]
	check(c["open"] == 0 and c["non_manifold"] == 0 and c["uv_seam"] + c["hard"] == 12 and box["vertices"] == 8,
		"a box: closed, its 12 edges seams or hard, 8 positions (%s)" % [c])
	var plane := GADSMeshDiagnostics.analyse(PlaneMesh.new())
	check(plane["counts"]["open"] == 4 and plane["counts"]["uv_seam"] == 0 and plane["counts"]["hard"] == 0 and (plane["notes"] as Array).size() == 1,
		"a plane: four open edges, nothing else")
	var sphere := GADSMeshDiagnostics.analyse(SphereMesh.new())
	check(sphere["counts"]["open"] == 0 and sphere["counts"]["non_manifold"] == 0 and sphere["counts"]["uv_seam"] > 0,
		"a sphere: closed, with its UV seam (%s, %d degenerate at the poles)" % [sphere["counts"], sphere["degenerate"]])
	# Three triangles on one edge, a degenerate one, two surfaces sharing an edge, no UVs.
	var am := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0.5, 1, 0), Vector3(0.5, -1, 0),
		Vector3(0.5, 0, 1), Vector3(2, 0, 0), Vector3(3, 0, 0), Vector3(4, 0, 0)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 1, 0, 3, 0, 1, 4, 5, 6, 7])
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var second := []
	second.resize(Mesh.ARRAY_MAX)
	second[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(1, 0, 0), Vector3(0.5, 1, 0), Vector3(1.5, 1, 0)])
	second[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)])
	second[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 2, 1])
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, second)
	var odd := GADSMeshDiagnostics.analyse(am)
	print("  %s" % GADSMeshDiagnostics.summary(odd).replace("\n", " | "))
	check(odd["counts"]["non_manifold"] == 1 and odd["degenerate"] == 1 and odd["counts"]["surface_border"] == 1 and odd["missing_uv"] == [0],
		"three triangles on an edge, a degenerate triangle, a border between surfaces and a surface without UVs are found")


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


## GADSProcedural: every kind of height map fills 0..1, tiles (the wrap-around column and row
## look like their neighbours), is the same for the same seed and differs for another; normals,
## occlusion and curvature of known shapes; a material and a texture set from a kind.
func test_procedural() -> void:
	print("\n== procedural height maps")
	if not GADSProcedural.is_available():
		check(false, "the native generator is loaded")
		return
	var kinds := GADSProcedural.get_kinds()
	var native: PackedStringArray = ClassDB.class_call_static(&"GADSHeightGenerator", &"get_kinds")
	var same := kinds.size() == native.size()
	for k in kinds:
		same = same and native.has(k)
	check(same and kinds.size() == 11, "a preset for each of the native generator's %d kinds" % native.size())
	var size := 128
	var bad := []
	var seams := []
	var started := Time.get_ticks_usec()
	for kind in kinds:
		var img := GADSProcedural.height_image(kind, size)
		if img == null or img.get_format() != Image.FORMAT_RF or img.get_width() != size:
			bad.append("%s: no RF %d image" % [kind, size])
			continue
		var h := img.get_data().to_float32_array()
		var lo := 1e9
		var hi := -1e9
		for v in h:
			lo = minf(lo, v)
			hi = maxf(hi, v)
		if lo < 0.0 or hi > 1.0 or hi - lo < 0.99:
			bad.append("%s: range %.3f..%.3f" % [kind, lo, hi])
		# Mean difference across each column boundary and each row boundary; the wrap-around
		# one (last to first) must not stand out from its two neighbours.
		for axis in 2:
			var b := PackedFloat32Array()
			b.resize(size)
			for k in size:
				var sum := 0.0
				for i in size:
					var a := h[i * size + k] if axis == 0 else h[k * size + i]
					var c := h[i * size + (k + 1) % size] if axis == 0 else h[((k + 1) % size) * size + i]
					sum += absf(a - c)
				b[k] = sum / size
			var wrap := b[size - 1]
			var around := maxf(b[size - 2], b[0])
			if wrap > 2.0 * around + 0.002:
				seams.append("%s %s: %.4f against %.4f" % [kind, "x" if axis == 0 else "y", wrap, around])
	var ms := (Time.get_ticks_usec() - started) / 1000.0
	print("  %d kinds at %d px in %.0f ms (with the checks)" % [kinds.size(), size, ms])
	check(bad.is_empty(), "every kind is a %d px float map spanning 0..1 %s" % [size, bad])
	check(seams.is_empty(), "every kind tiles: the wrap-around boundary is like its neighbours %s" % [seams])
	var a := GADSProcedural.height_image("stones", 64, {"seed": 4}).get_data()
	var b := GADSProcedural.height_image("stones", 64, {"seed": 4}).get_data()
	var c := GADSProcedural.height_image("stones", 64, {"seed": 5}).get_data()
	check(a == b and a != c, "the same seed gives the same map, another seed another")
	# Normals of a sine ramp along u: n = (-dh/du, 0, 1) normalised (OpenGL convention).
	var n := 64
	var ramp := Image.create(n, n, false, Image.FORMAT_RF)
	for y in n:
		for x in n:
			ramp.set_pixel(x, y, Color(0.5 + 0.5 * sin(TAU * (x + 0.5) / n), 0, 0))
	var depth := 0.1
	var nm := GADSProcedural.normal_image(ramp, depth, Vector2.ONE)
	var worst := 0.0
	for x in n:
		var slope := 0.5 * depth * TAU * cos(TAU * (x + 0.5) / n) # dh/du in m per m
		var want := Vector3(-slope, 0.0, 1.0).normalized()
		var px := nm.get_pixel(x, n / 2)
		var got := Vector3(px.r * 2.0 - 1.0, px.g * 2.0 - 1.0, px.b * 2.0 - 1.0)
		worst = maxf(worst, got.distance_to(want))
	check(nm.get_format() == Image.FORMAT_RGB8 and worst < 0.03, "normals of a sine ramp match its slope (largest difference %.3f)" % worst)
	# Occlusion: open on a flat map, closed in a pit; curvature: above 0.5 on a bump.
	var flat := Image.create(32, 32, false, Image.FORMAT_RF)
	flat.fill(Color(0.5, 0, 0))
	var ao_flat := GADSProcedural.ao_image(flat, 0.05).get_data().to_float32_array()
	var pit := Image.create(32, 32, false, Image.FORMAT_RF)
	for y in 32:
		for x in 32:
			var r := Vector2(x - 15.5, y - 15.5).length() / 6.0
			pit.set_pixel(x, y, Color(clampf(r * r, 0.0, 1.0), 0, 0))
	var ao_pit := GADSProcedural.ao_image(pit, 0.1, Vector2.ONE, 0.2)
	var curv_bump := GADSProcedural.curvature_image(GADSProcedural.height_image("craters", 64, {"count": 1, "scale": 1, "roughness": 0.0}), 3.0)
	check(ao_flat.count(1.0) == ao_flat.size() and ao_pit.get_pixel(16, 16).r < 0.8 and ao_pit.get_pixel(0, 0).r > ao_pit.get_pixel(16, 16).r,
		"occlusion is 1 on flat ground and lower in a pit (%.2f)" % ao_pit.get_pixel(16, 16).r)
	var curv := curv_bump.get_data().to_float32_array()
	var curv_lo := 1.0
	var curv_hi := 0.0
	for v in curv:
		curv_lo = minf(curv_lo, v)
		curv_hi = maxf(curv_hi, v)
	check(curv_lo < 0.4 and curv_hi > 0.6, "curvature: below 0.5 in a crater's bowl, above on its rim (%.2f..%.2f)" % [curv_lo, curv_hi])
	# A material in memory.
	var mat := GADSProcedural.create_material("bricks", {"size": 64, "mapping": GADSMaterials.Mapping.TRIPLANAR, "tile_m": Vector2(2, 2)})
	var tex_ok := mat != null and GADSMaterials.is_gads_material(mat)
	for key in ["height_texture", "normal_texture", "albedo_texture", "orm_texture"]:
		var t := mat.get_shader_parameter(key) as Texture2D if mat != null else null
		tex_ok = tex_ok and t != null and t.get_image().has_mipmaps()
	check(tex_ok and is_equal_approx(float(mat.get_shader_parameter("height_m")), 0.04) and mat.get_shader_parameter("texture_size_m") == Vector2(2, 2),
		"create_material: a triplanar GADS material with mipmapped maps, depth scaled with the tile (4 cm for 2 m bricks)")
	# A texture set the texture-set tools recognise.
	var dir := "user://gads_procedural_test"
	var written := GADSProcedural.write_texture_set("stones", dir, "pebbles", {"size": 64})
	var sets := GADSTextureSet.detect(PackedStringArray(written.values()))
	var roles: Array = (sets[0]["files"] as Dictionary).keys() if sets.size() == 1 else []
	roles.sort()
	check(written.size() == 4 and roles == ["albedo", "height", "normal", "orm"] and FileAccess.file_exists(String(written["height"]) + ".import"),
		"write_texture_set writes a set the texture-set tools read (%s)" % [roles])
	var exr := Image.load_from_file(ProjectSettings.globalize_path(written.get("height", "")))
	check(exr != null and exr.get_format() in [Image.FORMAT_RH, Image.FORMAT_RF], "the height is a float EXR")
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(dir.path_join(f)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(dir))

## Adaptive quality: one slow frame changes nothing; sustained slow frames step the preset down
## one step at a time (with a pause between steps) to the floor, then only coarsen runtime
## tessellation; room again steps it back up, never above the preset; switching it off restores
## the preset at once. Shared runtime budget: by coverage and priority, capped, with a minimum.
func test_adaptive_quality() -> void:
	print("\n== adaptive quality and runtime budget")
	var scene := Node3D.new()
	var gads := GADSManager.new()
	gads.preset = GADSSettings.Preset.HIGH
	gads.adaptive_min_preset = GADSSettings.Preset.LOW
	gads.target_frame_ms = 16.0
	scene.add_child(gads)
	root.add_child(scene)
	gads.adaptive_quality = true
	gads.set_process(false) # frames are fed by hand
	var steps: Array[int] = []
	gads.quality_adapted.connect(func(level: int) -> void: steps.append(level))
	var dt := 1.0 / 60.0
	for i in 240:
		gads.adapt_to(200.0 if i == 120 else 15.0, dt)
	check(gads.get_adapt_level() == 0 and steps.is_empty(), "one 200 ms frame among 15 ms ones changes nothing")
	var t := 0.0
	while gads.get_adapt_level() == 0 and t < 10.0:
		gads.adapt_to(25.0, dt)
		t += dt
	print("  first step down after %.2f s of 25 ms frames" % t)
	check(gads.get_adapt_level() == 1 and t >= 1.0 and t < 1.5 and gads.get_effective_preset() == GADSSettings.Preset.MEDIUM,
		"sustained 25 ms frames (target 16 ms) lower High to Medium after about a second")
	var levels := []
	t = 0.0
	while t < 30.0:
		gads.adapt_to(25.0, dt)
		t += dt
		if levels.is_empty() or levels.back() != gads.get_adapt_level():
			levels.append(gads.get_adapt_level())
	check(levels == [1, 2, 3, 4] and gads.get_effective_preset() == GADSSettings.Preset.LOW
		and is_equal_approx(gads.get_runtime_detail_scale(), pow(GADSManager.ADAPT_PIXEL_SCALE, 4)),
		"it keeps stepping one level at a time (%s): Low is the floor, further steps coarsen runtime tessellation" % [levels])
	await process_frame
	var applied: Vector4 = GADSGlobals.get_value(GADSGlobals.POM_STEPS)
	GADSSettings.create_preset(GADSSettings.Preset.HIGH).apply_globals()
	var high: Vector4 = GADSGlobals.get_value(GADSGlobals.POM_STEPS)
	GADSSettings.create_preset(GADSSettings.Preset.LOW).apply_globals()
	check(applied == GADSGlobals.get_value(GADSGlobals.POM_STEPS) and applied != high, "the Low preset's globals are in effect")
	t = 0.0
	var up_at := []
	while gads.get_adapt_level() > 0 and t < 120.0:
		var before := gads.get_adapt_level()
		gads.adapt_to(8.0, dt)
		t += dt
		if gads.get_adapt_level() != before:
			up_at.append(snappedf(t, 0.1))
	print("  back up at %s s" % [up_at])
	check(gads.get_adapt_level() == 0 and up_at.size() == 4 and up_at[0] >= 4.0 and gads.get_effective_preset() == GADSSettings.Preset.HIGH,
		"with room again (8 ms) it climbs back one step at a time, to the preset and no further")
	for i in 600:
		gads.adapt_to(2.0, dt)
	check(gads.get_adapt_level() == 0, "never above the preset")
	for i in 120:
		gads.adapt_to(40.0, dt)
	gads.adaptive_quality = false
	check(gads.get_adapt_level() == 0 and gads.get_effective_preset() == GADSSettings.Preset.HIGH, "switching it off restores the preset at once")
	scene.queue_free()
	# Shared budget.
	var shares := GADSManager.share_budget(1000000, [
		{"priority": 50, "radius": 1.0, "distance": 2.0, "max": 1000000},
		{"priority": 50, "radius": 1.0, "distance": 20.0, "max": 1000000},
		{"priority": 100, "radius": 1.0, "distance": 20.0, "max": 1000000},
		{"priority": 0, "radius": 1.0, "distance": 2.0, "max": 1000000},
	])
	print("  shares %s" % [shares])
	check(shares[0] > 90 * shares[1] and absi(shares[2] - 2 * shares[1]) <= 1 and shares[3] == GADSManager.MIN_SHARE,
		"a shared budget goes by the share of the view (near 100 x far) and the priority (2 x), priority 0 gets the minimum")
	var sum := 0
	for v in shares:
		sum += v
	check(sum <= 1000000 and sum > 1000000 - 4, "and adds up to the budget (%d)" % sum)
	var tiny := GADSManager.share_budget(10000, [
		{"priority": 50, "radius": 1.0, "distance": 2.0, "max": 1000000},
		{"priority": 50, "radius": 1.0, "distance": 40.0, "max": 1000000},
	])
	check(tiny[1] == GADSManager.MIN_SHARE and tiny[0] == 10000 - GADSManager.MIN_SHARE, "a share under the minimum gets the minimum, from the others' (%s)" % [tiny])
	var capped := GADSManager.share_budget(100000, [
		{"priority": 50, "radius": 1.0, "distance": 2.0, "max": 20000},
		{"priority": 50, "radius": 1.0, "distance": 20.0, "max": 1000000},
	])
	check(capped[0] == 20000 and capped[1] == 80000, "a node at its own maximum leaves the rest to the others (%s)" % [capped])


## Per-platform caps: the lowest matching cap wins, none on a desktop by default; a simulated phone
## gets Low; Custom is never capped; the capabilities report what this machine supports.
func test_platform_caps() -> void:
	print("\n== platform caps")
	var P := GADSSettings.Preset
	var caps := {"mobile": P.LOW, "web": P.LOW}
	check(GADSManager.platform_cap(caps, PackedStringArray(["windows", "pc", "forward_plus"])) == P.ULTRA, "no cap on a desktop")
	check(GADSManager.platform_cap(caps, PackedStringArray(["mobile", "android", "mobile_renderer"])) == P.LOW, "Low on a phone")
	check(GADSManager.platform_cap({"mobile_renderer": P.MEDIUM, "android": P.LOW}, PackedStringArray(["android", "mobile_renderer"])) == P.LOW,
		"the lowest matching cap wins")
	var scene := Node3D.new()
	var gads := GADSManager.new()
	gads.preset = P.ULTRA
	scene.add_child(gads)
	root.add_child(scene)
	check(gads.get_effective_preset() == P.ULTRA, "here (%s): Ultra stays Ultra" % [gads.get_platform_tags()])
	gads.simulate_platform = PackedStringArray(["mobile", "android"])
	gads.apply()
	var applied: Vector4 = GADSGlobals.get_value(GADSGlobals.POM_STEPS)
	GADSSettings.create_preset(P.LOW).apply_globals()
	check(gads.get_effective_preset() == P.LOW and applied == GADSGlobals.get_value(GADSGlobals.POM_STEPS), "a simulated phone runs Low (and its globals)")
	gads.preset = P.CUSTOM
	check(gads.get_effective_preset() == P.CUSTOM, "Custom settings are never capped")
	var info := gads.get_capabilities()
	check(info.has("renderer") and info["native_library"] == GADSMeshBaker.is_available() and info["cap"] == P.LOW and info["tags"] == PackedStringArray(["mobile", "android"]),
		"get_capabilities() reports the renderer, the native library, the tags and the cap (%s)" % [info])
	scene.queue_free()
	await process_frame


## GADSSculpt brush dabs: raise and lower by the strength at the centre, nothing at the radius;
## smooth lowers a spike; flatten levels towards a height.
func test_erosion() -> void:
	print("\n== erosion")
	if not GADSProcedural.is_available():
		check(false, "the native library is loaded")
		return
	# A cone 1 unit high over 50 texels: at 60 m a unit its flanks are 50 degrees, at 20 m 22.
	var n := 101
	var cone := Image.create(n, n, false, Image.FORMAT_RF)
	for y in n:
		for x in n:
			cone.set_pixel(x, y, Color(maxf(0.0, 1.0 - Vector2(x - 50, y - 50).length() / 50.0), 0, 0))
	var thermal := {"thermal_iterations": 2000, "talus_deg": 30.0, "thermal_rate": 0.5, "cell_m": 1.0}
	var steep := GADSProcedural.erode_image(cone, thermal.merged({"height_m": 60.0}))
	var gentle := GADSProcedural.erode_image(cone, thermal.merged({"height_m": 20.0}))
	var sum := func(img: Image) -> float:
		var s := 0.0
		for v in img.get_data().to_float32_array():
			s += v
		return s
	var max_slope := func(img: Image, height_m: float) -> float:
		var d := img.get_data().to_float32_array()
		var worst := 0.0
		for y in range(1, n - 1):
			for x in range(1, n - 1):
				var gx := (d[y * n + x + 1] - d[y * n + x - 1]) * 0.5 * height_m
				var gy := (d[(y + 1) * n + x] - d[(y - 1) * n + x]) * 0.5 * height_m
				worst = maxf(worst, Vector2(gx, gy).length())
		return rad_to_deg(atan(worst))
	var before_sum: float = sum.call(cone)
	print("  thermal: steepest flank %.1f -> %.1f degrees at 60 m a unit; %.1f at 20 m" % [max_slope.call(cone, 60.0), max_slope.call(steep, 60.0), max_slope.call(gentle, 20.0)])
	check(max_slope.call(steep, 60.0) < 34.0 and absf(float(sum.call(steep)) - before_sum) < 1e-3 * before_sum,
		"thermal erosion slides slopes steeper than the talus angle down to it, keeping the material")
	check(gentle.get_data() == cone.get_data(), "slopes under the talus angle stay (the scale makes the slope)")
	# Hydraulic: noise hills; ridges come down, valleys fill, the same seed gives the same field.
	var hills := GADSProcedural.height_image("noise", 128, {"seed": 4, "scale": 4.0})
	var water := {"droplets": 30000, "seed": 3, "cell_m": 1.0, "height_m": 20.0}
	var a := GADSProcedural.erode_image(hills, water)
	var b := GADSProcedural.erode_image(hills, water)
	var c := GADSProcedural.erode_image(hills, water.merged({"seed": 4}, true))
	var hd := hills.get_data().to_float32_array()
	var ad := a.get_data().to_float32_array()
	var order := range(hd.size())
	order.sort_custom(func(i: int, j: int) -> bool: return hd[i] < hd[j])
	var tenth := hd.size() / 10
	var low_before := 0.0
	var low_after := 0.0
	var high_before := 0.0
	var high_after := 0.0
	for k in tenth:
		low_before += hd[order[k]]
		low_after += ad[order[k]]
		high_before += hd[order[hd.size() - 1 - k]]
		high_after += ad[order[hd.size() - 1 - k]]
	print("  hydraulic: lowest tenth %+.4f, highest tenth %+.4f (mean change in units)" % [(low_after - low_before) / tenth, (high_after - high_before) / tenth])
	check(low_after > low_before and high_after < high_before, "water erosion takes the high ground down and fills the low")
	check(a.get_data() == b.get_data() and a.get_data() != c.get_data(), "the same seed erodes the same way, another seed differently")


func test_sculpt_brush() -> void:
	print("\n== sculpt brush")
	var img := GADSSculpt.new_image(64)
	GADSSculpt.dab(img, Vector2(0.5, 0.5), 0.1, GADSSculpt.Mode.RAISE, 0.01)
	var centre := img.get_pixel(32, 32).r
	var halfway := img.get_pixel(35, 32).r # (3.5, 0.5) texels from the centre (31.5, 31.5), radius 6.4
	var d := Vector2(3.5, 0.5).length() / 6.4
	var outside := img.get_pixel(32 + 7, 32).r
	check(centre > 0.0095 and absf(halfway - 0.01 * pow(1.0 - d * d, 2.0)) < 1e-5 and outside == 0.0,
		"raise: %.4f m at the centre, %.4f halfway out (a smooth falloff), 0 beyond" % [centre, halfway])
	GADSSculpt.dab(img, Vector2(0.5, 0.5), 0.1, GADSSculpt.Mode.LOWER, 0.01)
	check(absf(img.get_pixel(32, 32).r) < 1e-6, "lower takes it back")
	var spike := GADSSculpt.new_image(64)
	spike.set_pixel(32, 32, Color(0.05, 0, 0))
	GADSSculpt.dab(spike, Vector2(32.5 / 64.0, 32.5 / 64.0), 0.1, GADSSculpt.Mode.SMOOTH, 1.0)
	check(spike.get_pixel(32, 32).r < 0.01 and spike.get_pixel(33, 32).r > 0.0, "smooth spreads a spike (%.4f left)" % spike.get_pixel(32, 32).r)
	var hill := GADSSculpt.new_image(64)
	GADSSculpt.dab(hill, Vector2(0.5, 0.5), 0.2, GADSSculpt.Mode.RAISE, 0.02)
	GADSSculpt.dab(hill, Vector2(0.5, 0.5), 0.2, GADSSculpt.Mode.FLATTEN, 1.0, 0.005)
	check(absf(hill.get_pixel(32, 32).r - 0.005) < 1e-4, "flatten levels to a height (%.4f)" % hill.get_pixel(32, 32).r)
