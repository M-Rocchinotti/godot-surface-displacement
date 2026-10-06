extends SceneTree
## GADS on the Mobile and Compatibility renderers: every variant, the field with pebbles and a
## terrain compile and draw; the opt-in depth write lands at the right depth; runtime deformation
## changes the picture where the mark is and nowhere else.
##     python tools/godot.py --rendering-method gl_compatibility --script tests/renderer_tests.gd
##     python tools/godot.py --rendering-method mobile --script tests/renderer_tests.gd
## Shader compile errors are engine errors in the log (tests/run_all.py fails on them).

const Builder := preload("res://demo/scenes/demo_builder.gd")
const SIZE := Vector2i(480, 270)

var _passed := 0
var _failed := 0
var _viewport: SubViewport


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var method := RenderingServer.get_current_rendering_method()
	print("renderer: %s" % method)
	GADSGlobals.ensure_registered()
	_viewport = SubViewport.new()
	_viewport.size = SIZE
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_viewport)
	await _test_variants()
	await _test_depth_write()
	await _test_deformation()
	await _test_scenes()
	print("\nrenderer tests (%s): %d passed, %d failed" % [method, _passed, _failed])
	_viewport.queue_free()
	await process_frame
	await process_frame
	quit(1 if _failed > 0 else 0)


func check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		print("  ok   %s" % what)
	else:
		_failed += 1
		print("  FAIL %s" % what)


func _capture() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return _viewport.get_texture().get_image()


func _scene() -> Node3D:
	for child in _viewport.get_children():
		child.queue_free()
	var scene := Node3D.new()
	_viewport.add_child(scene)
	var we := WorldEnvironment.new()
	we.environment = Environment.new()
	we.environment.background_mode = Environment.BG_COLOR
	we.environment.background_color = Color(0, 0, 0)
	we.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	we.environment.ambient_light_color = Color(0.2, 0.2, 0.2)
	scene.add_child(we)
	return scene


static func _height(size: int, f: Callable) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RF)
	for y in size:
		for x in size:
			img.set_pixel(x, y, Color(f.call(x, y), 0, 0))
	img.convert(Image.FORMAT_RH)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _test_variants() -> void:
	print("\n== every variant draws")
	var scene := _scene()
	var cam := Camera3D.new()
	scene.add_child(cam)
	cam.look_at_from_position(Vector3(0, 3, 9), Vector3(0, 0, 0))
	cam.current = true
	var height := _height(64, func(x: int, y: int) -> float: return 0.5 + 0.5 * sin(x * 0.3) * sin(y * 0.3))
	var count := 0
	var x := -6.0
	for file in DirAccess.get_files_at(GADSMaterials.VARIANT_DIR):
		if not file.ends_with(".gdshader"):
			continue
		var info := GADSMaterials.parse(load(GADSMaterials.VARIANT_DIR + file))
		if info.is_empty():
			continue
		var m := GADSMaterials.create(info["mapping"], {"height": height}, {"height_m": 0.03}, info["quality"], info["depth_write"])
		m.shader = GADSMaterials.get_shader(info["mapping"], info["quality"], info["depth_write"], info["layered"])
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		mi.mesh.size = Vector3(0.3, 0.3, 0.3)
		mi.material_override = m
		mi.position = Vector3(x, 0, 0)
		x += 0.38
		scene.add_child(mi)
		count += 1
	for i in 5:
		await process_frame
	var img := await _capture()
	var lit := 0
	for px in range(0, SIZE.x, 4):
		var c := img.get_pixel(px, SIZE.y / 2)
		if c.r + c.g + c.b > 0.05:
			lit += 1
	check(count == 30 and lit > 20, "all %d surface variants draw (%d lit samples across the row)" % [count, lit])


## A depth-write wall without relief at 5 m and an unshaded red box 0.5 m in front of it: the box
## shows (the wall's written depth is where the wall is, in the renderer's depth range).
func _test_depth_write() -> void:
	print("\n== depth write")
	var scene := _scene()
	var cam := Camera3D.new()
	cam.near = 0.05
	cam.far = 100.0
	scene.add_child(cam)
	cam.look_at_from_position(Vector3(0, 0, 5), Vector3.ZERO)
	cam.current = true
	var flat := _height(16, func(_x: int, _y: int) -> float: return 1.0)
	var wall := MeshInstance3D.new()
	wall.mesh = QuadMesh.new()
	wall.mesh.size = Vector2(6, 4)
	wall.material_override = GADSMaterials.create(GADSMaterials.Mapping.UV, {"height": flat}, {"height_m": 0.02}, GADSMaterials.Quality.POM, true)
	scene.add_child(wall)
	var red := StandardMaterial3D.new()
	red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	red.albedo_color = Color(1, 0, 0)
	var box := MeshInstance3D.new()
	box.mesh = BoxMesh.new()
	box.mesh.size = Vector3(0.6, 0.6, 0.1)
	box.material_override = red
	box.position = Vector3(0, 0, 0.5)
	scene.add_child(box)
	for i in 5:
		await process_frame
	var img := await _capture()
	var c := img.get_pixel(SIZE.x / 2, SIZE.y / 2)
	var side := img.get_pixel(SIZE.x / 2 + 60, SIZE.y / 2)
	print("  centre %s, wall %s" % [c, side])
	check(c.r > 0.8 and c.g < 0.2, "the box in front of a depth-writing wall shows")
	check(side.r + side.g + side.b > 0.05 and not (side.r > 0.8 and side.g < 0.2), "the wall draws around it")


## A world-planar POM floor and a deformation mark: the picture changes inside the mark only.
func _test_deformation() -> void:
	print("\n== runtime deformation")
	var scene := _scene()
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35, 30, 0)
	scene.add_child(sun)
	var cam := Camera3D.new()
	scene.add_child(cam)
	cam.look_at_from_position(Vector3(0, 2.5, 2.5), Vector3.ZERO)
	cam.current = true
	var stones := _height(128, func(x: int, y: int) -> float: return 0.5 + 0.5 * sin(x * 0.2) * cos(y * 0.25))
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.mesh = PlaneMesh.new()
	floor_mesh.mesh.size = Vector2(8, 8)
	# A checker albedo: the parallax shift the mark adds moves it visibly.
	var checker := Image.create(64, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 64:
			checker.set_pixel(x, y, Color(0.9, 0.9, 0.9) if (x / 4 + y / 4) % 2 == 0 else Color(0.1, 0.1, 0.1))
	checker.generate_mipmaps()
	floor_mesh.material_override = GADSMaterials.create(GADSMaterials.Mapping.WORLD, {"height": stones, "albedo": ImageTexture.create_from_image(checker)},
		{"height_m": 0.03, "height_center": 0.0, "texture_size_m": Vector2(2, 2)}, GADSMaterials.Quality.POM_SELF_SHADOW)
	scene.add_child(floor_mesh)
	for i in 5:
		await process_frame
	var before := await _capture()
	var field := GADSDeformationField.new()
	field.size_m = 8.0
	field.resolution = 256
	scene.add_child(field)
	field.stamp(Vector3(0.0, 0.0, 0.0), 0.5, 0.06, 0.02, GADSDeformationField.Combine.ADD)
	for i in 5:
		await process_frame
	var after := await _capture()
	var mark := cam.unproject_position(Vector3.ZERO)
	var inside := 0.0
	var outside := 0.0
	for k in 9:
		var o := Vector2(k % 3 - 1, k / 3 - 1) * 8.0
		var a := Vector2i(mark + o)
		var b := Vector2i(mark + Vector2(170, 0) + o)
		inside += absf(after.get_pixelv(a).get_luminance() - before.get_pixelv(a).get_luminance())
		outside += absf(after.get_pixelv(b).get_luminance() - before.get_pixelv(b).get_luminance())
	print("  luminance change in the mark %.3f, beside it %.3f" % [inside / 9.0, outside / 9.0])
	check(inside / 9.0 > 0.01 and outside / 9.0 < 0.002, "the mark changes the floor under it and nothing beside it")


func _test_scenes() -> void:
	print("\n== demo scenes")
	for child in _viewport.get_children():
		child.queue_free()
	var ok := true
	var compatibility := RenderingServer.get_current_rendering_method() == "gl_compatibility"
	for index in Builder.SCENE_NAMES.size():
		var scene := Builder.build(index)
		_viewport.add_child(scene)
		(scene.get_node("Camera") as Camera3D).current = true
		var gads := scene.get_node("GADSManager") as GADSManager
		if index == 0:
			var field := scene.find_children("*", "GADSDisplacementField3D", true, false)[0] as GADSDisplacementField3D
			if field.is_baking():
				await field.baked
			gads.preset = GADSSettings.Preset.ULTRA
			await process_frame
			var drawn := field.get_mesh_instance().visible
			if compatibility:
				check(field.ground_bake == null and not drawn, "Compatibility: the field cannot capture the ground and stays off (the ground keeps its parallax)")
			else:
				check(field.ground_bake != null and drawn, "the field captures the ground and draws")
		for preset in [GADSSettings.Preset.LOW, GADSSettings.Preset.ULTRA]:
			gads.preset = preset
			for i in 8:
				await process_frame
			var img := await _capture()
			ok = ok and img != null and not img.is_invisible()
		scene.queue_free()
		await process_frame
	check(ok, "the %d demo scenes draw at Low and Ultra" % Builder.SCENE_NAMES.size())
